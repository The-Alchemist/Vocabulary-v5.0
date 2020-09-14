/**************************************************************************
* Copyright 2016 Observational Health Data Sciences and Informatics (OHDSI)
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
* 
* Authors: Dmitry Dymshyts, Timur Vakhitov
* Date: 2020
**************************************************************************/

--1. Update latest_update field to new date
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.SetLatestUpdate(
	pVocabularyName			=> 'ICD10GM',
	pVocabularyDate			=> (SELECT vocabulary_date FROM sources.icd10gm LIMIT 1),
	pVocabularyVersion		=> (SELECT vocabulary_version FROM sources.icd10gm LIMIT 1),
	pVocabularyDevSchema	=> 'DEV_ICD10GM'
);
END $_$;

drop table CS;
create table CS as
(select concept_code, last_concept_name, min_date as valid_start_date,
case
when max_date=to_date('20200101','yyyymmdd') then to_date('20991231','yyyymmdd')
else max_date-1+interval '1 year' end as valid_end_date
from (
select distinct concept_code,
first_value(concept_name) over (partition by concept_code order by vocabulary_date desc) as last_concept_name,
first_value(vocabulary_date) over (partition by concept_code order by vocabulary_date) as min_date,
first_value(vocabulary_date) over (partition by concept_code order by vocabulary_date desc) as max_date
from dev_icd10gm.icd10gm_all
) as s0
)
;

--2. Truncate all working tables
TRUNCATE TABLE concept_stage;
TRUNCATE TABLE concept_relationship_stage;
TRUNCATE TABLE concept_synonym_stage;
TRUNCATE TABLE pack_content_stage;
TRUNCATE TABLE drug_strength_stage;

--3. Fill the concept_stage from ICD10
INSERT INTO concept_stage (
	concept_name,
	domain_id,
	vocabulary_id,
	concept_class_id,
	standard_concept,
	concept_code,
	valid_start_date,
	valid_end_date
	)
SELECT c.concept_name,
	c.domain_id,
	'ICD10GM' AS vocabulary_id,
	c.concept_class_id,
	c.standard_concept,
	g.concept_code,
	g.valid_start_date,
	g.valid_end_date
FROM CS g
LEFT JOIN concept c ON c.concept_code = g.concept_code
	AND c.vocabulary_id = 'ICD10';
	
--4. Append concept corrections -- COVID concepts added, in the future ICD10 WHO "translation" considered to be better then "ours"
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.ProcessManualConcepts();
END $_$;

--5. Fill the concept_relationship_stage from ICD10
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date
	)
SELECT c1.concept_code AS concept_code_1,
	c2.concept_code AS concept_code_2,
	'ICD10GM' AS vocabulary_id_1,
	c2.vocabulary_id AS vocabulary_id_2,
	cr.relationship_id,
	cr.valid_start_date,
	cr.valid_end_date
FROM concept c1
JOIN concept_relationship cr ON cr.concept_id_1 = c1.concept_id and relationship_id in ('Maps to', 'Maps to value')
	AND cr.invalid_reason IS NULL
JOIN concept c2 ON c2.concept_id = cr.concept_id_2
WHERE c1.vocabulary_id = 'ICD10'
	AND EXISTS (
		SELECT 1
		FROM concept_stage cs_int
		WHERE cs_int.concept_code = c1.concept_code
		);

--6. Add "subsumes" relationship between concepts where the concept_code is like of another
CREATE INDEX IF NOT EXISTS trgm_idx ON concept_stage USING GIN (concept_code devv5.gin_trgm_ops); --for LIKE patterns
ANALYZE concept_stage;
INSERT INTO concept_relationship_stage (
	concept_code_1,
	concept_code_2,
	vocabulary_id_1,
	vocabulary_id_2,
	relationship_id,
	valid_start_date,
	valid_end_date
	)
SELECT c1.concept_code AS concept_code_1,
	c2.concept_code AS concept_code_2,
	c1.vocabulary_id AS vocabulary_id_1,
	c1.vocabulary_id AS vocabulary_id_2,
	'Subsumes' AS relationship_id,
	(
		SELECT latest_update
		FROM vocabulary
		WHERE vocabulary_id = c1.vocabulary_id
		) AS valid_start_date,
	TO_DATE('20991231', 'yyyymmdd') AS valid_end_date
FROM concept_stage c1,
	concept_stage c2
WHERE c2.concept_code LIKE c1.concept_code || '%'
	AND c1.concept_code <> c2.concept_code
;

DROP INDEX trgm_idx;
ANALYZE concept_relationship_stage;

--7. Append manual relationships
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.ProcessManualRelationships();
END $_$;

--8. Working with replacement mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.CheckReplacementMappings();
END $_$;

--9. Add mapping from deprecated to fresh concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMAPSTO();
END $_$;

--Same for 'Maps to value'
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.AddFreshMapsToValue();
END $_$;

--10. Deprecate 'Maps to' mappings to deprecated and upgraded concepts
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeprecateWrongMAPSTO();
END $_$;

--11. Delete ambiguous 'Maps to' mappings
DO $_$
BEGIN
	PERFORM VOCABULARY_PACK.DeleteAmbiguousMAPSTO();
END $_$;

--12. Update domain_id for ICD10GM from SNOMED
UPDATE concept_stage cs
SET domain_id = i.domain_id
FROM (
	SELECT DISTINCT crs.concept_code_1,
		FIRST_VALUE(c2.domain_id) OVER (
			PARTITION BY crs.concept_code_1 ORDER BY CASE c2.domain_id
					WHEN 'Condition'
						THEN 1
					WHEN 'Observation'
						THEN 2
					WHEN 'Procedure'
						THEN 3
					WHEN 'Measurement'
						THEN 4
					WHEN 'Device'
						THEN 5
					ELSE 6
					END
			) AS domain_id
	FROM concept_relationship_stage crs
	JOIN concept c2 ON c2.concept_code = crs.concept_code_2
		AND c2.vocabulary_id = crs.vocabulary_id_2
		AND c2.vocabulary_id = 'SNOMED'
	WHERE crs.relationship_id = 'Maps to'
		AND crs.invalid_reason IS NULL
		AND crs.vocabulary_id_1='ICD10GM'
	) i
WHERE i.concept_code_1 = cs.concept_code;

--Most of the concepts without ICD10WHO equivalent are Conditions, let's put Condition domain until we get the mapping done
UPDATE concept_stage
SET domain_id = 'Condition'
WHERE domain_id IS NULL;

--13. Fill concept_synonym_stage
INSERT INTO concept_synonym_stage (
	synonym_concept_code,
	synonym_name,
	synonym_vocabulary_id,
	language_concept_id
	)
SELECT concept_code AS synonym_concept_code,
	last_concept_name AS synonym_name,
	'ICD10GM' AS synonym_vocabulary_id,
	4182504 AS language_concept_id -- German
FROM CS
where concept_code not in 
(--manual additions, have to exclude them as in the source they are just "emergency code use" !!! to be removed in the next refresh
'U07.1','U07.2', 'U07.0', 'U99.0'
)
;
--manually adding synonyms (COVID19, E-cig)
DO $_$
BEGIN
     PERFORM VOCABULARY_PACK.ProcessManualSynonyms();
END $_$;

-- At the end, the three tables concept_stage, concept_relationship_stage and concept_synonym_stage should be ready to be fed into the generic_update.sql script