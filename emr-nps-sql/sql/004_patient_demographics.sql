-- =============================================================================
-- PROJECT: Sierra Leone EMR National Patient Summary (NPS)
-- FILE:    sql/004_patient_demographics.sql
-- TARGET:  PostgreSQL 17+
--
-- PURPOSE:
--   Parameterized extraction functions/queries for:
--     1. Issuer-qualified patient resolution (avoiding global-uniqueness assumptions)
--     2. Block 01: Document & provenance (NPS-01-01 to NPS-01-17)
--     3. Block 02: Patient & contacts (NPS-02-01 to NPS-02-15), including
--        privacy-aware masking of restricted contact details (NPS-02-10, NPS-02-15)
--        and fan-out-free extraction of 1..* identifiers and emergency contacts.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. ISSUER-QUALIFIED PATIENT RESOLUTION
--    Resolves internal patient_uid from (issuing_facility_id, source_patient_id)
-- =============================================================================
-- Only source identifiers (NPS-02-02) can resolve a patient. Ambiguous keys
-- and unresolved merges fail closed. All three inputs are supplied by the adapter.
CREATE FUNCTION nps.resolve_patient_uid(
    p_issuing_facility_id VARCHAR,
    p_source_patient_id VARCHAR,
    p_issuing_system VARCHAR
) RETURNS UUID
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH matches AS (
        SELECT p.patient_uid
          FROM nps.patient p
         WHERE (p.primary_source_facility_id, p.primary_source_system, p.primary_source_patient_id)
             = (p_issuing_facility_id, p_issuing_system, p_source_patient_id)
        UNION
        SELECT pi.patient_uid
          FROM nps.patient_identifier pi
         WHERE (pi.issuing_facility_id, pi.issuing_system, pi.identifier_value)
             = (p_issuing_facility_id, p_issuing_system, p_source_patient_id)
           AND pi.nps_element_id = 'NPS-02-02' AND pi.identifier_status = 'Active'
    )
    SELECT target.patient_uid
      FROM matches m JOIN nps.patient p USING (patient_uid)
      JOIN nps.patient target ON target.patient_uid = COALESCE(p.merged_into_patient_uid, p.patient_uid)
     WHERE (SELECT count(*) FROM matches) = 1
       AND p.record_status IN ('Active', 'Merged') AND target.record_status = 'Active';
$$;

-- =============================================================================
-- 2. BLOCK 01 EXTRACTION: DOCUMENT & PROVENANCE (NPS-01-01 to NPS-01-17)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_document_provenance(
    p_issuing_facility_id VARCHAR,
    p_source_patient_id   VARCHAR,
    p_issuing_system VARCHAR,
    p_document_uid        UUID DEFAULT NULL
)
RETURNS TABLE (
    document_uid            UUID,
    nps_01_01_document_id   VARCHAR,
    nps_01_02_version       VARCHAR,
    nps_01_03_patient_id    VARCHAR,
    nps_01_04_facility_id   VARCHAR,
    nps_01_05_source_emr    VARCHAR,
    nps_01_06_generated_at  TIMESTAMPTZ,
    nps_01_07_status        VARCHAR,
    nps_01_08_author        TEXT,
    nps_01_09_method        VARCHAR,
    nps_01_10_language      VARCHAR,
    nps_01_10_language_spec VARCHAR,
    nps_01_11_confidential  VARCHAR,
    nps_01_12_period_start  DATE,
    nps_01_12_period_end    DATE,
    nps_01_13_attester      TEXT,
    nps_01_14_attested_at   TIMESTAMPTZ,
    nps_01_15_custodian     TEXT,
    nps_01_16_received_at   TIMESTAMPTZ,
    nps_01_17_source_ref    VARCHAR,
    supersedes_document_uid UUID,
    updated_at              TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT d.document_uid,
           d.document_id             AS nps_01_01_document_id,
           d.document_version        AS nps_01_02_version,
           d.shared_patient_id       AS nps_01_03_patient_id,
           d.source_facility_id      AS nps_01_04_facility_id,
           d.source_emr              AS nps_01_05_source_emr,
           d.generated_date_time     AS nps_01_06_generated_at,
           d.document_status         AS nps_01_07_status,
           d.author_assembler        AS nps_01_08_author,
           d.generation_method       AS nps_01_09_method,
           d.language_choice         AS nps_01_10_language,
           d.language_other          AS nps_01_10_language_spec,
           d.confidentiality         AS nps_01_11_confidential,
           d.clinical_period_start   AS nps_01_12_period_start,
           d.clinical_period_end     AS nps_01_12_period_end,
           d.attester                AS nps_01_13_attester,
           d.attestation_date_time   AS nps_01_14_attested_at,
           d.custodian               AS nps_01_15_custodian,
           d.received_date_time      AS nps_01_16_received_at,
           d.source_record_reference AS nps_01_17_source_ref,
           d.supersedes_document_uid,
           d.updated_at
      FROM nps.summary_document d
      JOIN target_patient tp ON tp.patient_uid = d.patient_uid
     WHERE (p_document_uid IS NOT NULL AND d.document_uid = p_document_uid)
        OR (p_document_uid IS NULL     AND d.document_status = 'Current')
     ORDER BY d.generated_date_time DESC, d.version_number DESC, d.document_uid
     LIMIT 1;
$$;

COMMENT ON FUNCTION nps.extract_document_provenance(VARCHAR, VARCHAR, VARCHAR, UUID) IS
    'Extracts Block 01 (Document & provenance: NPS-01-01 to NPS-01-17) for one issuer-qualified patient.';

-- =============================================================================
-- 3. BLOCK 02 EXTRACTION: PATIENT DEMOGRAPHICS & CONTACTS (NPS-02-01 to NPS-02-15)
--    Prevents join fan-out by aggregating 1..* identifiers and 0..* contacts
--    in isolated subqueries, and enforces contact_permission masking.
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_patient_demographics(
    p_issuing_facility_id        VARCHAR,
    p_source_patient_id          VARCHAR,
    p_issuing_system VARCHAR,
    p_include_restricted_contact BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    patient_uid                      UUID,
    nps_01_03_shared_patient_id      VARCHAR,
    nps_02_01_patient_name           TEXT,
    nps_02_02_source_patient_id      VARCHAR,
    nps_02_02_issuing_facility_id    VARCHAR,
    nps_02_02_issuing_system         VARCHAR,
    nps_02_03_other_identifiers_json JSONB,
    nps_02_04_sex                    VARCHAR,
    nps_02_05_date_of_birth_raw      VARCHAR,
    nps_02_05_date_of_birth_exact    DATE,
    nps_02_05_dob_precision          VARCHAR,
    nps_02_06_age_value              NUMERIC,
    nps_02_06_age_unit               VARCHAR,
    nps_02_07_age_assessment_date    DATE,
    nps_02_08_estimated_birth_date   VARCHAR,
    nps_02_09_vital_status           VARCHAR,
    nps_02_10_phone_number           VARCHAR,
    nps_02_11_district               VARCHAR,
    nps_02_12_chiefdom               VARCHAR,
    nps_02_13_locality               TEXT,
    nps_02_14_emergency_contacts     JSONB,
    nps_02_15_contact_permission     VARCHAR,
    record_status                    VARCHAR,
    updated_at                       TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT p.patient_uid,
           COALESCE(
               p.mpi_patient_id,
               jsonb_build_array(p.primary_source_facility_id, p.primary_source_system, p.primary_source_patient_id)::text::varchar
           ) AS nps_01_03_shared_patient_id,
           p.patient_name               AS nps_02_01_patient_name,
           p.primary_source_patient_id  AS nps_02_02_source_patient_id,
           p.primary_source_facility_id AS nps_02_02_issuing_facility_id,
           p.primary_source_system      AS nps_02_02_issuing_system,
           -- Isolated subquery for NPS-02-02 & NPS-02-03 prevents Cartesian multiplication with contacts
           COALESCE(
               (
                   SELECT jsonb_agg(
                              jsonb_build_object(
                                  'npsElementId',      pi.nps_element_id,
                                  'identifierType',    pi.identifier_type,
                                  'identifierValue',   pi.identifier_value,
                                  'issuingFacilityId', pi.issuing_facility_id,
                                  'issuingSystem',     pi.issuing_system,
                                  'isPrimarySourceId', pi.is_primary_source_id,
                                  'status',            pi.identifier_status
                              )
                              ORDER BY pi.is_primary_source_id DESC, pi.nps_element_id ASC, pi.identifier_type ASC
                          )
                     FROM nps.patient_identifier pi
                    WHERE pi.patient_uid = p.patient_uid
                      AND pi.identifier_status = 'Active'
                      AND pi.nps_element_id = 'NPS-02-03'
               ),
               '[]'::jsonb
           ) AS nps_02_03_other_identifiers_json,
           p.sex                     AS nps_02_04_sex,
           p.date_of_birth_raw       AS nps_02_05_date_of_birth_raw,
           p.date_of_birth_exact     AS nps_02_05_date_of_birth_exact,
           p.date_of_birth_precision AS nps_02_05_dob_precision,
           p.age_at_assessment_value AS nps_02_06_age_value,
           p.age_at_assessment_unit  AS nps_02_06_age_unit,
           p.date_of_age_assessment  AS nps_02_07_age_assessment_date,
           p.estimated_birth_date    AS nps_02_08_estimated_birth_date,
           p.vital_status            AS nps_02_09_vital_status,
           -- NPS-02-10 & NPS-02-15: Mask phone number when contact permission is Restricted unless caller is authorized
           CASE
               WHEN NOT COALESCE(p_include_restricted_contact, FALSE)
                   THEN NULL
               ELSE p.phone_number
           END                       AS nps_02_10_phone_number,
           p.district                AS nps_02_11_district,
           p.chiefdom                AS nps_02_12_chiefdom,
           p.locality                AS nps_02_13_locality,
           -- Isolated subquery for NPS-02-14 emergency contacts
           COALESCE(
               (
                   SELECT jsonb_agg(
                              jsonb_build_object(
                                  'contactName',           cp.contact_name,
                                  'relationship',          cp.relationship,
                                  'phoneNumber',           CASE
                                                               WHEN NOT COALESCE(p_include_restricted_contact, FALSE)
                                                                   THEN NULL
                                                               ELSE cp.phone_number
                                                           END,
                                  'contactPermission',     cp.contact_permission,
                                  'isLegalRepresentative', cp.is_legal_representative
                              )
                              ORDER BY cp.created_at ASC
                          )
                     FROM nps.patient_contact_person cp
                    WHERE cp.patient_uid = p.patient_uid
                      AND cp.record_status = 'Active'
               ),
               '[]'::jsonb
           ) AS nps_02_14_emergency_contacts,
           p.contact_permission      AS nps_02_15_contact_permission,
           p.record_status,
           p.updated_at
      FROM nps.patient p
      JOIN target_patient tp ON tp.patient_uid = p.patient_uid;
$$;

COMMENT ON FUNCTION nps.extract_patient_demographics(VARCHAR, VARCHAR, VARCHAR, BOOLEAN) IS
    'Extracts Block 02 (Patient & contacts: NPS-02-01 to NPS-02-15) without row multiplication and masks restricted phone numbers unless authorized.';

-- =============================================================================
-- 4. SEPARATE TABULAR QUERY FOR PATIENT IDENTIFIERS (NPS-02-02 & NPS-02-03)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_patient_identifiers(
    p_issuing_facility_id VARCHAR,
    p_source_patient_id   VARCHAR,
    p_issuing_system VARCHAR
)
RETURNS TABLE (
    identifier_uid       UUID,
    nps_element_id       VARCHAR,
    identifier_type      VARCHAR,
    identifier_value     VARCHAR,
    issuing_facility_id  VARCHAR,
    issuing_system       VARCHAR,
    is_primary_source_id BOOLEAN,
    identifier_status    VARCHAR,
    recorded_at          TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT pi.identifier_uid,
           pi.nps_element_id,
           pi.identifier_type,
           pi.identifier_value,
           pi.issuing_facility_id,
           pi.issuing_system,
           pi.is_primary_source_id,
           pi.identifier_status,
           pi.recorded_at
      FROM nps.patient_identifier pi
      JOIN target_patient tp ON tp.patient_uid = pi.patient_uid
     WHERE pi.identifier_status <> 'Entered in error'
     ORDER BY pi.is_primary_source_id DESC, pi.nps_element_id ASC, pi.identifier_type ASC;
$$;

-- =============================================================================
-- 5. SEPARATE TABULAR QUERY FOR EMERGENCY CONTACTS (NPS-02-14 & NPS-02-15)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_patient_contacts(
    p_issuing_facility_id        VARCHAR,
    p_source_patient_id          VARCHAR,
    p_issuing_system VARCHAR,
    p_include_restricted_contact BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    contact_uid             UUID,
    nps_02_14_contact_name  TEXT,
    nps_02_14_relationship  VARCHAR,
    nps_02_14_phone_number  VARCHAR,
    nps_02_15_permission    VARCHAR,
    is_legal_representative BOOLEAN,
    record_status           VARCHAR
)
LANGUAGE sql
STABLE
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT cp.contact_uid,
           cp.contact_name AS nps_02_14_contact_name,
           cp.relationship AS nps_02_14_relationship,
           CASE
               WHEN NOT COALESCE(p_include_restricted_contact, FALSE)
                   THEN NULL
               ELSE cp.phone_number
           END             AS nps_02_14_phone_number,
           cp.contact_permission AS nps_02_15_permission,
           cp.is_legal_representative,
           cp.record_status
      FROM nps.patient_contact_person cp
      JOIN nps.patient p     ON p.patient_uid = cp.patient_uid
      JOIN target_patient tp ON tp.patient_uid = cp.patient_uid
     WHERE cp.record_status = 'Active'
     ORDER BY cp.created_at ASC;
$$;

COMMIT;

