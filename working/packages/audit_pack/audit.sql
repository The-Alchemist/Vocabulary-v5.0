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
* Authors: Timur Vakhitov
* Date: 2021
**************************************************************************/

--1. Create a schema for logs
CREATE SCHEMA audit AUTHORIZATION devv5;
ALTER DEFAULT PRIVILEGES IN SCHEMA audit GRANT SELECT ON TABLES TO role_read_only;
GRANT USAGE ON SCHEMA audit TO role_read_only;

--2. Create a table for logs
CREATE TABLE audit.logged_actions (
	log_id INT4 GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
	table_name TEXT NOT NULL,
	tg_operation TEXT NOT NULL CHECK (tg_operation IN ('I','D','U','T')), --I=insert, D=delete, U=update, T=truncate
	user_name TEXT NOT NULL,
	tx_time TIMESTAMPTZ NOT NULL, --current transaction timestamp
	statement_time TIMESTAMPTZ NOT NULL, --current statement timestamp
	op_time TIMESTAMPTZ NOT NULL, --current timestamp (for row)
	old_row JSONB,
	new_row JSONB,
	client_ip INET,
	client_app_name TEXT,
	query TEXT NOT NULL,
	script_name TEXT, --function stack
	tx_id INT4 NOT NULL --current transaction ID
);

--3. Create a function for stack parsing. NOTE: this is an imprecise approach to getting function names, but there are no other easy ways
CREATE OR REPLACE FUNCTION audit.GetFunctionStack (iStack text) RETURNS TEXT AS
$BODY$
	SELECT STRING_AGG(COALESCE(r.pretty_function_name,s0.function_name), ' -> ' ORDER BY s0.pos DESC)
	FROM (
		SELECT SUBSTRING(s.objects, '^PL/pgSQL function .*?\.?([^.]+?)\(.*?\) line') function_name,
			s.pos
		FROM UNNEST(REGEXP_SPLIT_TO_ARRAY(iStack, E'\r?\n+')) WITH ORDINALITY AS s(objects, pos)
		WHERE s.pos>1
		) s0
	--replace function names with their "pretty" forms
	LEFT JOIN (
		SELECT *
		FROM UNNEST(
			ARRAY ['StartRelease','SetLatestUpdate','UpdateAllVocabularies','GenericUpdate',
				'AddNewConcept','AddNewDomain','AddNewSynonym','AddNewConceptClass','AddNewRelationship',
				'AddNewVocabulary','MoveToDevV5','pConceptAncestor',
				--admin_pack functions
				'LogManualChanges','ModifyVocabularyAccess','ModifyVirtualUser','ModifyUserPrivilege',
				'ModifyPrivilege','GrantVocabularyAccess','GrantPrivilege','CreateVirtualUser',
				'CreatePrivilege','ChangeOwnPassword','DeleteManualRelationship'
				]
			) AS replacements(pretty_function_name)
		) r ON LOWER(r.pretty_function_name)=s0.function_name;
$BODY$ LANGUAGE 'sql' IMMUTABLE STRICT;

--4. Create a function for triggers
CREATE OR REPLACE FUNCTION audit.f_tg_audit() RETURNS TRIGGER AS
$BODY$
DECLARE
	pDiff TEXT;
	pOLDROW JSONB;
	pNEWROW JSONB;
	pOperation TEXT:=LEFT(TG_OP,1);
	pStack TEXT;
BEGIN
	GET DIAGNOSTICS pStack = PG_CONTEXT;

	IF TG_OP='UPDATE' THEN
		pOLDROW:=TO_JSONB(OLD);
		pNEWROW:=TO_JSONB(NEW);
	ELSIF TG_OP='INSERT' THEN
		pNEWROW:=TO_JSONB(NEW);
	ELSIF TG_OP='DELETE' THEN
		pOLDROW:=TO_JSONB(OLD);
	END IF;

	INSERT INTO audit.logged_actions
	VALUES (
		DEFAULT,
		TG_TABLE_NAME::TEXT,
		pOperation,
		SESSION_USER,
		TRANSACTION_TIMESTAMP(),
		STATEMENT_TIMESTAMP(),
		CLOCK_TIMESTAMP(),
		pOLDROW,
		pNEWROW,
		INET_CLIENT_ADDR(),
		CURRENT_SETTING('application_name'),
		CURRENT_QUERY(),
		audit.GetFunctionStack(pStack),
		TXID_CURRENT()
	);

	RETURN NULL;
END;
$BODY$
LANGUAGE 'plpgsql' SECURITY DEFINER;

--5. Create triggers for all required tables
DO $$
DECLARE
	pTables TEXT[]:=ARRAY['concept','concept_relationship','concept_synonym','drug_strength','pack_content','relationship','vocabulary','vocabulary_conversion','concept_class','domain'];
	t TEXT;
BEGIN
	FOR t IN (SELECT * FROM UNNEST(pTables)) LOOP
		EXECUTE FORMAT('
		CREATE TRIGGER tg_audit_u
		AFTER UPDATE ON %I
		FOR EACH ROW
		WHEN (OLD.* IS DISTINCT FROM NEW.*)
		EXECUTE PROCEDURE audit.f_tg_audit()',t);

		EXECUTE FORMAT('
		CREATE TRIGGER tg_audit_id
		AFTER INSERT OR DELETE ON %I
		FOR EACH ROW
		EXECUTE PROCEDURE audit.f_tg_audit()',t);

		EXECUTE FORMAT('
		CREATE TRIGGER tg_audit_t
		AFTER TRUNCATE ON %I
		FOR EACH STATEMENT
		EXECUTE PROCEDURE audit.f_tg_audit()',t);
	END LOOP;
END $$;

--6. Create indexes
CREATE INDEX idx_audit_old_concept_id ON audit.logged_actions (((old_row ->> 'concept_id')::INT4));
CREATE INDEX idx_audit_new_concept_id ON audit.logged_actions (((new_row ->> 'concept_id')::INT4));
CREATE INDEX idx_audit_old_concept_id1 ON audit.logged_actions (((old_row ->> 'concept_id_1')::INT4));
CREATE INDEX idx_audit_new_concept_id1 ON audit.logged_actions (((new_row ->> 'concept_id_1')::INT4));
CREATE INDEX idx_audit_new_rel_concept_id ON audit.logged_actions (((new_row ->> 'relationship_concept_id')::INT4));
CREATE INDEX idx_audit_old_rel_concept_id ON audit.logged_actions (((old_row ->> 'relationship_concept_id')::INT4));
CREATE INDEX idx_audit_new_voc_concept_id ON audit.logged_actions (((new_row ->> 'vocabulary_concept_id')::INT4));
CREATE INDEX idx_audit_old_voc_concept_id ON audit.logged_actions (((old_row ->> 'vocabulary_concept_id')::INT4));
CREATE INDEX idx_audit_new_class_concept_id ON audit.logged_actions (((new_row ->> 'concept_class_concept_id')::INT4));
CREATE INDEX idx_audit_old_class_concept_id ON audit.logged_actions (((old_row ->> 'concept_class_concept_id')::INT4));
CREATE INDEX idx_audit_new_domain_concept_id ON audit.logged_actions (((new_row ->> 'domain_concept_id')::INT4));
CREATE INDEX idx_audit_old_domain_concept_id ON audit.logged_actions (((old_row ->> 'domain_concept_id')::INT4));
CREATE INDEX idx_audit_new_drug_concept_id ON audit.logged_actions (((new_row ->> 'drug_concept_id')::INT4));
CREATE INDEX idx_audit_old_drug_concept_id ON audit.logged_actions (((old_row ->> 'drug_concept_id')::INT4));
CREATE INDEX idx_audit_new_pack_concept_id ON audit.logged_actions (((new_row ->> 'pack_concept_id')::INT4));
CREATE INDEX idx_audit_old_pack_concept_id ON audit.logged_actions (((old_row ->> 'pack_concept_id')::INT4));
CREATE INDEX idx_audit_tx_time ON audit.logged_actions USING BRIN (tx_time);
CREATE INDEX idx_audit_tx_id ON audit.logged_actions USING BRIN (tx_id);