-- with new download
drop table dev_civic.genomic_civic_variantsummaries_new;
create table dev_civic.genomic_civic_variantsummaries_new (
    variant_id int,
    variant_civic_url varchar(255),
    gene varchar(255),
    entrez_id int,
    variant varchar(255),
    summary text,
    variant_groups varchar(255),
    chromosome varchar(255),
    start int,
    stop int,
    reference_bases varchar(255),
    variant_bases varchar(255),
    representative_transcript varchar(255),
    ensembl_version int,
    reference_build varchar(255),
    chromosome2 varchar(255),
    start2 int,
    stop2 int,
    representative_transcript2 varchar(255),
    variant_types varchar(255),
    hgvs_expressions varchar(255),
    last_review_date varchar(255),
    civic_variant_evidence_score float,
    allele_registry_id varchar(255),
    clinvar_ids varchar(255),
    variant_aliases varchar(255),
    assertion_ids varchar(255),
    assertion_civic_urls varchar(255),
    is_flagged varchar(255)
);


-- with existing sources
DROP TABLE IF EXISTS dev_civic.genomic_civic_variantsummaries;
CREATE TABLE dev_civic.genomic_civic_variantsummaries
as (select * from sources.genomic_civic_variantsummaries);