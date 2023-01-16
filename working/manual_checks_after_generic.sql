--01. Concept changes
--01.1. Concepts changed their Domain
select new.concept_code,
       new.concept_name as concept_name,
       new.concept_class_id as concept_class_id,
       new.standard_concept as standard_concept,
       new.vocabulary_id as vocabulary_id,
       old.domain_id as old_domain_id,
       new.domain_id as new_domain_id
from concept new
join devv5.concept old
    using (concept_id)
where old.domain_id != new.domain_id
;

--01.2. Domain of newly added concepts
SELECT c1.concept_code,
       c1.concept_name,
       c1.concept_class_id,
       c1.vocabulary_id,
       c1.standard_concept,
       c1.domain_id as new_domain
FROM concept c1
LEFT JOIN devv5.concept c2
    ON c1.concept_id = c2.concept_id
WHERE c2.vocabulary_id IS NULL
;

--01.3. Concepts changed their names
SELECT c.concept_code,
       c.vocabulary_id,
       c2.concept_name as old_name,
       c.concept_name as new_name,
       devv5.similarity (c2.concept_name, c.concept_name)
FROM concept c
JOIN devv5.concept c2
    ON c.concept_id = c2.concept_id
        AND c.concept_name != c2.concept_name
WHERE c.vocabulary_id IN (:your_vocabs)
ORDER BY devv5.similarity (c2.concept_name, c.concept_name)
;


--01.4. Concepts changed their synonyms
with old_syn as (

SELECT c.concept_code,
       c.vocabulary_id,
       cs.language_concept_id,
       array_agg (DISTINCT cs.concept_synonym_name ORDER BY cs.concept_synonym_name) as old_synonym
FROM devv5.concept c
JOIN devv5.concept_synonym cs
    ON c.concept_id = cs.concept_id
WHERE c.vocabulary_id IN (:your_vocabs)
GROUP BY c.concept_code,
       c.vocabulary_id,
       cs.language_concept_id
),

new_syn as (

SELECT c.concept_code,
       c.vocabulary_id,
       cs.language_concept_id,
       array_agg (DISTINCT cs.concept_synonym_name ORDER BY cs.concept_synonym_name) as new_synonym
FROM concept c
JOIN concept_synonym cs
    ON c.concept_id = cs.concept_id
WHERE c.vocabulary_id IN (:your_vocabs)
GROUP BY c.concept_code,
       c.vocabulary_id,
       cs.language_concept_id
)

SELECT DISTINCT
       o.concept_code,
       o.vocabulary_id,
       o.old_synonym,
       n.new_synonym,
       devv5.similarity (o.old_synonym::varchar, n.new_synonym::varchar)
FROM old_syn o

LEFT JOIN new_syn n
    ON o.concept_code = n.concept_code
        AND o.vocabulary_id = n.vocabulary_id
        AND o.language_concept_id = n.language_concept_id

WHERE o.old_synonym != n.new_synonym OR n.new_synonym IS NULL

ORDER BY devv5.similarity (o.old_synonym::varchar, n.new_synonym::varchar)
;


--02. Mapping of concepts
--02.1. looking at new concepts and their mapping -- 'Maps to' absent
select a.concept_code as concept_code_source,
       a.concept_name as concept_name_source,
       a.vocabulary_id as vocabulary_id_source,
       a.concept_class_id as concept_class_id_source,
       a.domain_id as domain_id_source,
       b.concept_name as concept_name_target,
       b.vocabulary_id as vocabulary_id_target
 from concept a
left join concept_relationship r on a.concept_id= r.concept_id_1 and r.invalid_reason is null and r.relationship_Id ='Maps to'
left join concept  b on b.concept_id = r.concept_id_2
left join devv5.concept  c on c.concept_id = a.concept_id
where a.vocabulary_id IN (:your_vocabs)
and c.concept_id is null and b.concept_id is null
;

--02.2. looking at new concepts and their mapping -- 'Maps to', 'Maps to value' present
select a.concept_code as concept_code_source,
       a.concept_name as concept_name_source,
       a.vocabulary_id as vocabulary_id_source,
       a.concept_class_id as concept_class_id_source,
       a.domain_id as domain_id_source,
       r.relationship_id,
       CASE WHEN a.concept_id = b.concept_id and r.relationship_id ='Maps to' THEN '<Mapped to itself>'
           ELSE b.concept_name END as concept_name_target,
       CASE WHEN a.concept_id = b.concept_id and r.relationship_id ='Maps to' THEN '<Mapped to itself>'
           ELSE b.vocabulary_id END as vocabulary_id_target
from concept a
join concept_relationship r
    on a.concept_id=r.concept_id_1
           and r.invalid_reason is null
           and r.relationship_Id in ('Maps to', 'Maps to value')
join concept b
    on b.concept_id = r.concept_id_2
left join devv5.concept  c
    on c.concept_id = a.concept_id
where a.vocabulary_id IN (:your_vocabs)
    and c.concept_id is null
    --and a.concept_id != b.concept_id --use it to exclude mapping to itself
order by a.concept_code
;

--02.3. looking at new concepts and their ancestry -- 'Is a' absent
select a.concept_code, a.concept_name, a.concept_class_id, a.domain_id, b.concept_name, b.concept_class_id, b.vocabulary_id
from concept a
left join concept_relationship r on a.concept_id= r.concept_id_1 and r.invalid_reason is null and r.relationship_Id ='Is a'
left join concept b on b.concept_id = r.concept_id_2
left join devv5.concept  c on c.concept_id = a.concept_id
where a.vocabulary_id IN (:your_vocabs)
and c.concept_id is null and b.concept_id is null
;

--02.4. looking at new concepts and their ancestry -- 'Is a' present
select a.concept_code, a.concept_name, a.concept_class_id, a.domain_id, b.concept_name, b.concept_class_id, b.vocabulary_id
from concept a
join concept_relationship r on a.concept_id= r.concept_id_1 and r.invalid_reason is null and r.relationship_Id ='Is a'
join concept  b on b.concept_id = r.concept_id_2
left join devv5.concept  c on c.concept_id = a.concept_id
where a.vocabulary_id IN (:your_vocabs)
and c.concept_id is null
;

--02.5. concepts changed their mapping ('Maps to'), this includes 2 scenarios: mapping changed; mapping present in one version, absent in another;
--to detect the absent mappings cases, sort by the respective code_agg to get the NULL values first.
with new_map as (
select a.concept_id,
       a.vocabulary_id,
       a.concept_class_id,
       a.standard_concept,
       a.concept_code,
       a.concept_name,
       string_agg (r.relationship_id, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as relationship_agg,
       string_agg (b.concept_code, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as code_agg,
       string_agg (b.concept_name, '-/-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as name_agg
from concept a
left join concept_relationship r on a.concept_id = concept_id_1 and r.relationship_id in ('Maps to', 'Maps to value') and r.invalid_reason is null
left join concept b on b.concept_id = concept_id_2
where a.vocabulary_id IN (:your_vocabs)
    --and a.invalid_reason is null --to exclude invalid concepts
group by a.concept_id, a.vocabulary_id, a.concept_class_id, a.standard_concept, a.concept_code, a.concept_name
)
,
old_map as (
select a.concept_id,
       a.vocabulary_id,
       a.concept_class_id,
       a.standard_concept,
       a.concept_code,
       a.concept_name,
       string_agg (r.relationship_id, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as relationship_agg,
       string_agg (b.concept_code, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as code_agg,
       string_agg (b.concept_name, '-/-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as name_agg
from devv5.concept a
left join devv5.concept_relationship r on a.concept_id = concept_id_1 and r.relationship_id in ('Maps to', 'Maps to value') and r.invalid_reason is null
left join devv5.concept b on b.concept_id = concept_id_2
where a.vocabulary_id IN (:your_vocabs)
    --and a.invalid_reason is null --to exclude invalid concepts
group by a.concept_id, a.vocabulary_id, a.concept_class_id, a.standard_concept, a.concept_code, a.concept_name
)
select b.vocabulary_id as vocabulary_id,
       b.concept_class_id,
       b.standard_concept,
       b.concept_code as source_code,
       b.concept_name as source_name,
       a.relationship_agg as old_relat_agg,
       a.code_agg as old_code_agg,
       a.name_agg as old_name_agg,
       b.relationship_agg as new_relat_agg,
       b.code_agg as new_code_agg,
       b.name_agg as new_name_agg
from old_map a
join new_map b
on a.concept_id = b.concept_id and ((coalesce (a.code_agg, '') != coalesce (b.code_agg, '')) or (coalesce (a.relationship_agg, '') != coalesce (b.relationship_agg, '')))
order by a.concept_code
;

--02.6. Concepts changed their ancestry ('Is a'), this includes 2 scenarios: Ancestor(s) changed; ancestor(s) present in one version, absent in another;
--to detect the absent ancestry cases, sort by the respective code_agg to get the NULL values first.
with new_map as (
select a.concept_id,
       a.vocabulary_id,
       a.concept_class_id,
       a.standard_concept,
       a.concept_code,
       a.concept_name,
       string_agg (r.relationship_id, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as relationship_agg,
       string_agg (b.concept_code, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as code_agg,
       string_agg (b.concept_name, '-/-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as name_agg
from concept a
left join concept_relationship r on a.concept_id = concept_id_1 and r.relationship_id in ('Is a') and r.invalid_reason is null
left join concept b on b.concept_id = concept_id_2
where a.vocabulary_id IN (:your_vocabs) and a.invalid_reason is null
group by a.concept_id, a.vocabulary_id, a.concept_class_id, a.standard_concept, a.concept_code, a.concept_name
)
,
old_map as (
select a.concept_id,
       a.vocabulary_id,
       a.concept_class_id,
       a.standard_concept,
       a.concept_code,
       a.concept_name,
       string_agg (r.relationship_id, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as relationship_agg,
       string_agg (b.concept_code, '-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as code_agg,
       string_agg (b.concept_name, '-/-' order by r.relationship_id, b.concept_code, b.vocabulary_id) as name_agg
from devv5. concept a
left join devv5.concept_relationship r on a.concept_id = concept_id_1 and r.relationship_id in ('Is a') and r.invalid_reason is null
left join devv5.concept b on b.concept_id = concept_id_2
where a.vocabulary_id IN (:your_vocabs) and a.invalid_reason is null
group by a.concept_id, a.vocabulary_id, a.concept_class_id, a.standard_concept, a.concept_code, a.concept_name
)
select b.vocabulary_id as vocabulary_id,
       b.concept_class_id,
       b.standard_concept,
       b.concept_code as source_code,
       b.concept_name as source_name,
       a.relationship_agg as old_relat_agg,
       a.code_agg as old_code_agg,
       a.name_agg as old_name_agg,
       b.relationship_agg as new_relat_agg,
       b.code_agg as new_code_agg,
       b.name_agg as new_name_agg
from old_map  a
join new_map b
on a.concept_id = b.concept_id and ((coalesce (a.code_agg, '') != coalesce (b.code_agg, '')) or (coalesce (a.relationship_agg, '') != coalesce (b.relationship_agg, '')))
order by a.concept_code
;

--02.7. Concepts with 1-to-many mapping -- multiple 'Maps to' present
select a.vocabulary_id,
       a.concept_code as concept_code_source,
       a.concept_name as concept_name_source,
       a.concept_class_id as concept_class_id_source,
       a.domain_id as domain_id_source,
       b.concept_code as concept_code_target,
       CASE WHEN a.concept_id = b.concept_id THEN '<Mapped to itself>'
           ELSE b.concept_name END as concept_name_target,
       CASE WHEN a.concept_id = b.concept_id THEN '<Mapped to itself>'
           ELSE b.vocabulary_id END as vocabulary_id_target
from concept a
join concept_relationship r
    on a.concept_id=r.concept_id_1
           and r.invalid_reason is null
           and r.relationship_Id ='Maps to'
join concept b
    on b.concept_id = r.concept_id_2
where a.vocabulary_id IN (:your_vocabs)
    --and a.concept_id != b.concept_id --use it to exclude mapping to itself
    and a.concept_id IN (
                            select a.concept_id
                            from concept a
                            join concept_relationship r
                                on a.concept_id=r.concept_id_1
                                       and r.invalid_reason is null
                                       and r.relationship_Id ='Maps to'
                            join concept b
                                on b.concept_id = r.concept_id_2
                            where a.vocabulary_id IN (:your_vocabs)
                                --and a.concept_id != b.concept_id --use it to exclude mapping to itself
                            group by a.concept_id
                            having count(*) > 1
    )
;

--02.8. Concepts became non-Standard with no mapping replacement
select a.concept_code,
       a.concept_name,
       a.concept_class_id,
       a.domain_id,
       a.vocabulary_id
from concept a
join devv5.concept b
        on a.concept_id = b.concept_id
where a.vocabulary_id IN (:your_vocabs)
    and b.standard_concept = 'S'
    and a.standard_concept IS NULL
    and not exists (
                    SELECT 1
                    FROM concept_relationship cr
                    WHERE a.concept_id = cr.concept_id_1
                        AND cr.relationship_id = 'Maps to'
                        AND cr.invalid_reason IS NULL
    )
;

--02.9. Concepts are presented in CRM with "Maps to" link, but end up with no valid "Maps to"
SELECT *
FROM concept c
WHERE c.vocabulary_id IN (:your_vocabs)
    AND EXISTS (SELECT 1
                FROM concept_relationship_manual crm
                WHERE c.concept_code = crm.concept_code_1
                    AND c.vocabulary_id = crm.vocabulary_id_1
                    AND crm.relationship_id = 'Maps to' AND crm.invalid_reason IS NULL)
AND NOT EXISTS (SELECT 1
                FROM concept_relationship cr
                WHERE c.concept_id = cr.concept_id_1
                    AND cr.relationship_id = 'Maps to'
                    AND cr.invalid_reason IS NULL)
;

--02.10. Mapping of vaccines
--move to the project-specific QA folder and adjust exclusion criteria in there
--adjust inclusion criteria here if needed: https://github.com/OHDSI/Vocabulary-v5.0/blob/master/RxNorm_E/manual_work/specific_qa/vaccine%20selection.sql
with vaccine_exclusion as (SELECT
    'placeholder|placeholder' as vaccine_exclusion
    )

select distinct c.vocabulary_id,
                c.concept_name,
                c.concept_class_id,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.concept_name END as target_concept_name,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.concept_class_id END as target_concept_class_id,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.vocabulary_id END as target_vocabulary_id
from concept c
left join concept_relationship cr on cr.concept_id_1 = c.concept_id and relationship_id ='Maps to' and cr.invalid_reason is null
left join concept b on b.concept_id = cr.concept_id_2
where c.vocabulary_id IN (:your_vocabs)

    and ((c.concept_name ~* (select vaccine_inclusion from dev_rxe.vaccine_inclusion) and c.concept_name !~* (select vaccine_exclusion from vaccine_exclusion))
        or
        (b.concept_name ~* (select vaccine_inclusion from dev_rxe.vaccine_inclusion) and b.concept_name !~* (select vaccine_exclusion from vaccine_exclusion)))
;

--02.11. Mapping of covid concepts (please adjust inclusion/exclusion in the master branch if found something)
with covid_inclusion as (SELECT
        'sars(?!(tedt|aparilla))|^cov(?!(er|onia|aWound|idien))|cov$|^ncov|ncov$|corona(?!(l|ry|ries| radiata))|severe acute|covid(?!ien)' as covid_inclusion
    ),

covid_exclusion as (SELECT
    '( |^)LASSARS' as covid_exclusion
    )


select distinct c.vocabulary_id,
                c.concept_name,
                c.concept_class_id,
                cr.relationship_id,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.concept_name END as target_concept_name,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.concept_class_id END as target_concept_class_id,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.vocabulary_id END as target_vocabulary_id
from concept c
left join concept_relationship cr on cr.concept_id_1 = c.concept_id and relationship_id IN ('Maps to', 'Maps to value') and cr.invalid_reason is null
left join concept b on b.concept_id = cr.concept_id_2
where c.vocabulary_id IN (:your_vocabs)

    and ((c.concept_name ~* (select covid_inclusion from covid_inclusion) and c.concept_name !~* (select covid_exclusion from covid_exclusion))
        or
        (b.concept_name ~* (select covid_inclusion from covid_inclusion) and b.concept_name !~* (select covid_exclusion from covid_exclusion)))
;

--03. Check we don't add duplicative concepts
SELECT CASE WHEN string_agg (DISTINCT c2.concept_id::text, '-') IS NULL THEN 'new concept' ELSE 'old concept' END as when_added,
       c.concept_name,
       string_agg (DISTINCT c2.concept_id::text, '-') as concept_id
FROM concept c
LEFT JOIN devv5.concept c2
    ON c.concept_id = c2.concept_id
WHERE c.vocabulary_id IN (:your_vocabs)
    AND c.invalid_reason IS NULL
GROUP BY c.concept_name
HAVING COUNT (*) >1
ORDER BY when_added, concept_name
;

--04. Concepts have replacement link, but miss "Maps to" link
SELECT DISTINCT cr.concept_id_1, cr.relationship_id, cc.standard_concept
FROM concept_relationship cr
JOIN concept c
    ON c.concept_id = cr.concept_id_1
LEFT JOIN concept cc
    ON cc.concept_id = cr.concept_id_2
WHERE c.vocabulary_id IN (:your_vocabs)
    AND EXISTS (SELECT concept_id_1
                FROM concept_relationship cr1
                WHERE cr1.relationship_id IN ('Concept replaced by', 'Concept same_as to', 'Concept alt_to to', 'Concept was_a to')
                    AND cr1.invalid_reason IS NULL
                    AND cr1.concept_id_1 = cr.concept_id_1)
    AND NOT EXISTS (SELECT concept_id_1
                    FROM concept_relationship cr2
                    WHERE cr2.relationship_id IN ('Maps to')
                        AND cr2.invalid_reason IS NULL
                        AND cr2.concept_id_1 = cr.concept_id_1)
    AND cr.relationship_id IN ('Concept replaced by', 'Concept same_as to', 'Concept alt_to to', 'Concept was_a to')
ORDER BY cr.relationship_id, cc.standard_concept, cr.concept_id_1
;

-- 06. Mapping of visit concepts
--In this check we manually review the mapping of visits to the 'Visit' domain.
--To prioritize and make the review process more structured, the logical groups to be identified using the sorting by flag and flag_visit_should_be. Then the content to be reviewed separately within the groups.
-- -- Three flags are used:
-- -- - 'incorrect mapping' - indicates the concepts that are probably visits but mapped to domains other than 'Visit';
-- -- - 'review mapping to visit' - indicates concepts that are mapped to the 'Visit' domain but the target_concept_id differs from the reference;
-- -- - 'correct mapping' - indicates the concepts mapped to the reference target visits.
-- -- The flag_visit_should_be field contains the most commonly used types of visits that could be the target for your mapping, and also flag 'other visit' that may indicate the relatively rarely used concepts in the 'Visit' domain.
-- Because of mapping complexity and trickiness, and depending on the way the mappings were produced, full manual review may be needed.
-- Please adjust inclusion/exclusion in the master branch if found something
WITH home_visit AS (SELECT ('(?!(morp))home(?!(tr|opath))|domiciliary') as home_visit),
    outpatient_visit AS (SELECT ('outpatient|out.patient|ambul(?!(ance|ation))|office(?!(r))') as outpatient_visit),
    ambulance_visit AS (SELECT ('ambulance|transport(?!(er))') AS ambulance_visit),
    emergency_room_visit AS (SELECT ('emerg|(\W)ER(\W)') AS emergency_room_visit),
    pharmacy_visit AS (SELECT ('(\W)pharm(\s)|pharmacy') AS pharmacy_visit),
    inpatient_visit AS (SELECT ('inpatient|in.patient|(\W)hosp(?!(ice|h|ira))') AS inpatient_visit),
    telehealth AS (SELECT ('(?!(pla))tele(?!(t|scop))|remote|video') AS telehealth),
    other_visit AS (SELECT ('clinic(?!(al))|(\W)center(\W)|(\W)facility|visit|institution|encounter|rehab|hospice|nurs|school|(\W)unit(\W)') AS other_visit),
    visit_exclusion AS (SELECT 'estrogen' AS visit_exclusion),

flag AS (SELECT DISTINCT c.concept_code,
                c.concept_name,
                c.vocabulary_id,
                b.concept_id as target_concept_id,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.concept_name END AS target_concept_name,
                CASE WHEN c.concept_id = b.concept_id THEN '<Mapped to itself>'
                    ELSE b.vocabulary_id END AS target_vocabulary_id,
                b.domain_id AS target_domain_id,
                              CASE WHEN c.concept_name ~* (SELECT home_visit FROM home_visit) AND
                                       b.concept_id != '581476' THEN 'home visit'
                                  WHEN c.concept_name ~* (SELECT outpatient_visit FROM outpatient_visit) AND
                                       b.concept_id != '9202' THEN 'outpatient visit'
                                  WHEN c.concept_name ~* (SELECT ambulance_visit FROM ambulance_visit) AND
                                       b.concept_id != '581478' THEN 'ambulance visit'
                                  WHEN c.concept_name ~* (SELECT emergency_room_visit FROM emergency_room_visit) AND
                                       b.concept_id != '9203' THEN 'emergency room visit'
                                  WHEN c.concept_name ~* (SELECT pharmacy_visit FROM pharmacy_visit) AND
                                       b.concept_id != '581458' THEN 'pharmacy visit'
                                  WHEN c.concept_name ~* (SELECT inpatient_visit FROM inpatient_visit) AND
                                       b.concept_id != '9201' THEN 'inpatient visit'
                                  WHEN c.concept_name ~* (SELECT telehealth FROM telehealth) AND
                                       b.concept_id != '5083' THEN 'telehealth'
                                  WHEN c.concept_name ~* (SELECT other_visit FROM other_visit)
                                        THEN 'other visit'
                                  END AS flag_visit_should_be
FROM concept c
LEFT JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id AND relationship_id ='Maps to' AND cr.invalid_reason IS NULL
LEFT JOIN concept b ON b.concept_id = cr.concept_id_2
WHERE c.vocabulary_id IN (:your_vocabs)
AND c.concept_name !~* (SELECT visit_exclusion FROM visit_exclusion)),

incorrect_mapping AS (SELECT concept_code,
                concept_name,
                vocabulary_id,
                target_concept_id,
                target_concept_name,
                target_vocabulary_id,
                'incorrect_mapping' AS flag,
                flag_visit_should_be
FROM flag
WHERE target_domain_id != 'Visit'),

review_mapping_to_visit AS (SELECT concept_code,
                concept_name,
                vocabulary_id,
                target_concept_id,
                target_concept_name,
                target_vocabulary_id,
                'review_mapping_to_visit' AS flag,
                flag_visit_should_be
FROM flag
WHERE target_domain_id = 'Visit'),

correct_mapping AS (SELECT DISTINCT c.concept_code,
                c.concept_name,
                c.vocabulary_id,
                b.concept_id AS target_concept_id,
                b.concept_name AS target_concept_name,
                b.vocabulary_id AS target_vocabulary_id,
                'correct mapping' AS flag,
                NULL AS flag_visit_should_be
FROM concept c
LEFT JOIN concept_relationship cr ON cr.concept_id_1 = c.concept_id AND relationship_id ='Maps to' AND cr.invalid_reason IS NULL
LEFT JOIN concept b ON b.concept_id = cr.concept_id_2
WHERE c.vocabulary_id IN (:your_vocabs)
AND b.concept_id IN (581476, 9202, 581478, 9203, 581458, 9201, 5083)
)

SELECT vocabulary_id,
       concept_code,
       concept_name,
       flag,
       flag_visit_should_be,
       target_concept_id,
       target_concept_name,
       target_vocabulary_id
FROM incorrect_mapping
WHERE flag_visit_should_be IS NOT NULL
             AND concept_code NOT IN (SELECT concept_code from review_mapping_to_visit) -- concepts mapped 1-to-many to visit + other domain should not be flagged as incorrect
             AND concept_code NOT IN (SELECT concept_code FROM correct_mapping) -- concepts mapped 1-to-many to visit + other domain should not be flagged as incorrect

UNION ALL

SELECT vocabulary_id,
       concept_code,
       concept_name,
       flag,
       flag_visit_should_be,
       target_concept_id,
       target_concept_name,
       target_vocabulary_id
FROM review_mapping_to_visit
        WHERE flag_visit_should_be IS NOT NULL

UNION ALL

SELECT vocabulary_id,
       concept_code,
       concept_name,
       flag,
       flag_visit_should_be,
       target_concept_id,
       target_concept_name,
       target_vocabulary_id
FROM correct_mapping

ORDER BY flag,
    flag_visit_should_be,
    vocabulary_id,
    concept_code
;