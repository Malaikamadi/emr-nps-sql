-- =============================================================================
-- PROJECT: Sierra Leone EMR National Patient Summary (NPS)
-- FILE:    sql/005_clinical_sections.sql
-- TARGET:  PostgreSQL 17+
--
-- PURPOSE:
--   Separate, parameterized SQL extraction functions for every NPS clinical
--   and completeness block (NPS-03 through NPS-20).
--   Each function:
--     - Identifies the patient using an issuer-qualified (facility + patient ID) pair
--     - Preserves all NPS-04 provenance metadata and original clinical dates
--     - Avoids multi-table 1..* join fan-out (row multiplication)
--     - Distinguishes Active/Corrected records from Superseded/Entered-in-error records
--     - Never fabricates clinical values when source fields are NULL/unknown
-- =============================================================================

BEGIN;

-- =============================================================================
-- BLOCK 03: SECTION COMPLETENESS EXTRACTION (NPS-03-01 to NPS-03-06)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_section_completeness(
    p_issuing_facility_id VARCHAR,
    p_source_patient_id   VARCHAR,
    p_issuing_system VARCHAR,
    p_document_uid        UUID DEFAULT NULL
)
RETURNS TABLE (
    nps_block_code                     VARCHAR,
    nps_03_01_nps_block                VARCHAR,
    priority_level                     VARCHAR,
    nps_03_02_information_status       VARCHAR,
    nps_03_03_extraction_status        VARCHAR,
    nps_03_04_last_assessed_date       DATE,
    nps_03_05_reason_unavailable       VARCHAR,
    nps_03_05_reason_unavailable_other TEXT,
    nps_03_06_access_restriction       VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_doc AS (
        SELECT d.document_uid
          FROM nps.extract_document_provenance(p_issuing_facility_id, p_source_patient_id, p_issuing_system, p_document_uid) d
    )
    SELECT bc.block_code                                           AS nps_block_code,
           bc.block_name                                           AS nps_03_01_nps_block,
           bc.priority_level,
           COALESCE(sc.section_information_status, 'Unknown')      AS nps_03_02_information_status,
           sc.extraction_status                                      AS nps_03_03_extraction_status,
           sc.last_assessed_date                                   AS nps_03_04_last_assessed_date,
           COALESCE(
               sc.reason_information_unavailable,
               CASE WHEN sc.section_completeness_uid IS NULL THEN 'Not recorded' END
           )                                                       AS nps_03_05_reason_unavailable,
           sc.reason_unavailable_other                             AS nps_03_05_reason_unavailable_other,
           COALESCE(sc.section_access_restriction, 'Normal')       AS nps_03_06_access_restriction
      FROM nps.block_catalog bc
      CROSS JOIN target_doc td
      LEFT JOIN nps.section_completeness sc
        ON sc.document_uid   = td.document_uid
       AND sc.nps_block_code = bc.block_code
     WHERE bc.is_clinical_section = TRUE
     ORDER BY bc.block_code ASC;
$$;

COMMENT ON FUNCTION nps.extract_section_completeness(VARCHAR, VARCHAR, VARCHAR, UUID) IS
    'Extracts Block 03 (Section completeness: NPS-03-01 to NPS-03-06) across all clinical blocks, defaulting unrecorded sections to Unknown/Unsupported rather than None known.';

-- =============================================================================
-- BLOCK 04: COMMON CLINICAL METADATA EXTRACTION (NPS-04-01 to NPS-04-10)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_clinical_entry_metadata(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_nps_block_code              VARCHAR DEFAULT NULL,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_block_code                   VARCHAR,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_05_event_timestamp        TIMESTAMPTZ,
    nps_04_05_event_date_precision   VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_04_10_original_code_system   VARCHAR,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID,
    updated_at                       TIMESTAMPTZ
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.nps_block_code,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.clinical_event_timestamp      AS nps_04_05_event_timestamp,
           ce.clinical_event_date_precision AS nps_04_05_event_date_precision,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ce.original_code_system          AS nps_04_10_original_code_system,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid,
           ce.updated_at
      FROM nps.clinical_entry ce
      JOIN target_patient tp ON tp.patient_uid = ce.patient_uid
     WHERE (p_nps_block_code IS NULL OR ce.nps_block_code = p_nps_block_code)
       AND (
           p_include_superseded_or_error = TRUE
           OR ce.record_lifecycle_status IN ('Active', 'Corrected')
       )
     ORDER BY COALESCE(ce.clinical_event_timestamp, ce.date_recorded, ce.created_at) DESC,
              ce.clinical_entry_id ASC;
$$;

-- =============================================================================
-- BLOCK 05: PROBLEMS & DIAGNOSES EXTRACTION (NPS-05-01 to NPS-05-08)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_problems_diagnoses(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_04_10_original_code_system   VARCHAR,
    nps_05_01_problem_code           VARCHAR,
    nps_05_01_problem_text           TEXT,
    nps_05_02_problem_status         VARCHAR,
    nps_05_03_diagnosis_certainty    VARCHAR,
    nps_05_04_onset_date_raw         VARCHAR,
    nps_05_04_onset_date_exact       DATE,
    nps_05_05_resolution_date_raw    VARCHAR,
    nps_05_05_resolution_date_exact  DATE,
    nps_05_06_severity               VARCHAR,
    nps_05_06_severity_other         TEXT,
    nps_05_07_diagnosis_basis        VARCHAR,
    nps_05_08_management_note        TEXT,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ce.original_code_system          AS nps_04_10_original_code_system,
           pd.problem_diagnosis_code        AS nps_05_01_problem_code,
           pd.problem_diagnosis_text        AS nps_05_01_problem_text,
           pd.problem_status                AS nps_05_02_problem_status,
           pd.diagnosis_certainty           AS nps_05_03_diagnosis_certainty,
           pd.onset_date_raw                AS nps_05_04_onset_date_raw,
           pd.onset_date_exact              AS nps_05_04_onset_date_exact,
           pd.resolution_date_raw           AS nps_05_05_resolution_date_raw,
           pd.resolution_date_exact         AS nps_05_05_resolution_date_exact,
           pd.severity                      AS nps_05_06_severity,
           pd.severity_other                AS nps_05_06_severity_other,
           pd.diagnosis_basis               AS nps_05_07_diagnosis_basis,
           pd.management_note               AS nps_05_08_management_note,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.problem_diagnosis pd
      JOIN nps.clinical_entry ce ON ce.entry_uid = pd.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = pd.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE pd.problem_status WHEN 'Active' THEN 1 WHEN 'Unknown' THEN 2 ELSE 3 END,
              COALESCE(pd.onset_date_exact, ce.date_recorded::date) DESC NULLS LAST,
              ce.clinical_entry_id ASC;
$$;

-- =============================================================================
-- BLOCK 06: ALLERGIES & INTOLERANCES EXTRACTION (NPS-06-01 to NPS-06-08)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_allergies_intolerances(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_06_01_allergen_code          VARCHAR,
    nps_06_01_allergen_text          TEXT,
    nps_06_02_allergy_status         VARCHAR,
    nps_06_03_verification_status    VARCHAR,
    nps_06_04_allergy_category       VARCHAR,
    nps_06_05_reaction_code          VARCHAR,
    nps_06_05_reaction_text          TEXT,
    nps_06_06_reaction_severity      VARCHAR,
    nps_06_07_criticality            VARCHAR,
    nps_06_08_first_noted_date_raw   VARCHAR,
    nps_06_08_first_noted_date       DATE,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ai.allergen_code                 AS nps_06_01_allergen_code,
           ai.allergen_text                 AS nps_06_01_allergen_text,
           ai.allergy_status                AS nps_06_02_allergy_status,
           ai.verification_status           AS nps_06_03_verification_status,
           ai.allergy_category              AS nps_06_04_allergy_category,
           ai.reaction_code                 AS nps_06_05_reaction_code,
           ai.reaction_text                 AS nps_06_05_reaction_text,
           ai.reaction_severity             AS nps_06_06_reaction_severity,
           ai.criticality                   AS nps_06_07_criticality,
           ai.first_noted_date_raw          AS nps_06_08_first_noted_date_raw,
           ai.first_noted_date              AS nps_06_08_first_noted_date,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.allergy_intolerance ai
      JOIN nps.clinical_entry ce ON ce.entry_uid = ai.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ai.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE ai.allergy_status WHEN 'Active' THEN 1 WHEN 'Unknown' THEN 2 ELSE 3 END,
              CASE ai.criticality WHEN 'High' THEN 1 ELSE 2 END,
              ai.first_noted_date DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 07: MEDICATION SUMMARY EXTRACTION (NPS-07-01 to NPS-07-11)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_medication_summary(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_07_01_medicine_code          VARCHAR,
    nps_07_01_medicine_name          TEXT,
    nps_07_02_medication_status      VARCHAR,
    nps_07_03_evidence_of_use        VARCHAR,
    nps_07_04_strength               TEXT,
    nps_07_05_dose_value             NUMERIC,
    nps_07_05_dose_unit              VARCHAR,
    nps_07_05_dose_text              TEXT,
    nps_07_06_route                  VARCHAR,
    nps_07_06_route_other            TEXT,
    nps_07_07_frequency              TEXT,
    nps_07_08_start_date_raw         VARCHAR,
    nps_07_08_start_date             DATE,
    nps_07_09_end_date_raw           VARCHAR,
    nps_07_09_end_date               DATE,
    nps_07_10_reason_code            VARCHAR,
    nps_07_10_reason_text            TEXT,
    nps_07_11_prescriber_id          VARCHAR,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ms.medicine_code                 AS nps_07_01_medicine_code,
           ms.medicine_name                 AS nps_07_01_medicine_name,
           ms.medication_status             AS nps_07_02_medication_status,
           ms.evidence_of_use               AS nps_07_03_evidence_of_use,
           ms.strength                      AS nps_07_04_strength,
           ms.dose_value                    AS nps_07_05_dose_value,
           ms.dose_unit                     AS nps_07_05_dose_unit,
           ms.dose_text                     AS nps_07_05_dose_text,
           ms.route                         AS nps_07_06_route,
           ms.route_other                   AS nps_07_06_route_other,
           ms.frequency                     AS nps_07_07_frequency,
           ms.start_date_raw                AS nps_07_08_start_date_raw,
           ms.start_date                    AS nps_07_08_start_date,
           ms.end_date_raw                  AS nps_07_09_end_date_raw,
           ms.end_date                      AS nps_07_09_end_date,
           ms.reason_for_use_code           AS nps_07_10_reason_code,
           ms.reason_for_use_text           AS nps_07_10_reason_text,
           ms.prescriber_id                 AS nps_07_11_prescriber_id,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.medication_summary ms
      JOIN nps.clinical_entry ce ON ce.entry_uid = ms.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ms.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE ms.medication_status WHEN 'Active' THEN 1 WHEN 'Unknown' THEN 2 ELSE 3 END,
              ms.start_date DESC NULLS LAST,
              ce.clinical_entry_id ASC;
$$;

-- =============================================================================
-- BLOCK 08: IMMUNIZATIONS EXTRACTION (NPS-08-01 to NPS-08-08)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_immunizations(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                            UUID,
    nps_04_01_clinical_entry_id          VARCHAR,
    nps_04_02_source_facility            VARCHAR,
    nps_04_03_source_system              VARCHAR,
    nps_04_04_date_recorded              TIMESTAMPTZ,
    nps_04_05_event_date_raw             VARCHAR,
    nps_04_06_original_description       TEXT,
    nps_04_07_source_provider            VARCHAR,
    nps_04_08_source_encounter           VARCHAR,
    nps_04_09_verification               VARCHAR,
    nps_04_10_original_clinical_code     VARCHAR,
    nps_08_01_vaccine_code               VARCHAR,
    nps_08_01_vaccine_text               TEXT,
    nps_08_02_administration_status      VARCHAR,
    nps_08_03_date_administered_raw      VARCHAR,
    nps_08_03_date_administered_exact    DATE,
    nps_08_03_date_unknown_reason        TEXT,
    nps_08_04_dose_number                VARCHAR,
    nps_08_05_vaccine_batch              VARCHAR,
    nps_08_06_evidence_source            VARCHAR,
    nps_08_06_evidence_source_other      TEXT,
    nps_08_07_administering_facility_id  VARCHAR,
    nps_08_08_next_dose_due_date         DATE,
    record_lifecycle_status              VARCHAR,
    replaces_entry_uid                   UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id                AS nps_04_01_clinical_entry_id,
           ce.source_facility_id               AS nps_04_02_source_facility,
           ce.source_system                    AS nps_04_03_source_system,
           ce.date_recorded                    AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw          AS nps_04_05_event_date_raw,
           ce.original_recorded_description    AS nps_04_06_original_description,
           ce.source_provider_id               AS nps_04_07_source_provider,
           ce.source_encounter_id              AS nps_04_08_source_encounter,
           ce.verification                     AS nps_04_09_verification,
           ce.original_clinical_code           AS nps_04_10_original_clinical_code,
           im.vaccine_code                     AS nps_08_01_vaccine_code,
           im.vaccine_text                     AS nps_08_01_vaccine_text,
           im.administration_status            AS nps_08_02_administration_status,
           im.date_administered_raw            AS nps_08_03_date_administered_raw,
           im.date_administered_exact          AS nps_08_03_date_administered_exact,
           im.date_administered_unknown_reason AS nps_08_03_date_unknown_reason,
           im.dose_number                      AS nps_08_04_dose_number,
           im.vaccine_batch                    AS nps_08_05_vaccine_batch,
           im.evidence_source                  AS nps_08_06_evidence_source,
           im.evidence_source_other            AS nps_08_06_evidence_source_other,
           im.administering_facility_id        AS nps_08_07_administering_facility_id,
           im.next_dose_due_date               AS nps_08_08_next_dose_due_date,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.immunization im
      JOIN nps.clinical_entry ce ON ce.entry_uid = im.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = im.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY im.date_administered_exact DESC NULLS LAST,
              ce.clinical_entry_id ASC;
$$;

-- =============================================================================
-- BLOCK 09: LABORATORY & IMAGING RESULTS EXTRACTION (NPS-09-01 to NPS-09-12)
--           Aggregates 1..* result items per report without row multiplication
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_laboratory_imaging_results(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_09_01_report_id              VARCHAR,
    nps_09_02_report_type            VARCHAR,
    nps_09_03_test_or_study_code     VARCHAR,
    nps_09_03_test_or_study_text     TEXT,
    nps_09_04_report_status          VARCHAR,
    nps_09_08_report_result_time     TIMESTAMPTZ,
    nps_09_11_imaging_conclusion     TEXT,
    nps_09_result_items_json         JSONB,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           dr.report_id                     AS nps_09_01_report_id,
           dr.report_type                   AS nps_09_02_report_type,
           dr.test_or_study_code            AS nps_09_03_test_or_study_code,
           dr.test_or_study_text            AS nps_09_03_test_or_study_text,
           dr.report_status                 AS nps_09_04_report_status,
           dr.result_date_time              AS nps_09_08_report_result_time,
           dr.imaging_conclusion            AS nps_09_11_imaging_conclusion,
           COALESCE(
               (
                   SELECT jsonb_agg(
                              jsonb_build_object(
                                  'resultItemUid',                ri.result_item_uid,
                                  'nps0905ResultItemCode',        ri.result_item_code,
                                  'nps0905ResultItemText',        ri.result_item_text,
                                  'nps0906ResultValueNumeric',    ri.result_value_numeric,
                                  'nps0906ResultValueChoice',     ri.result_value_choice,
                                  'nps0906ResultValueNarrative',  ri.result_value_narrative,
                                  'nps0907ResultUnit',            ri.result_unit,
                                  'nps0908ResultDateTime',        ri.result_date_time,
                                  'nps0909ReferenceRange',        ri.reference_range,
                                  'nps0910Interpretation',        ri.interpretation,
                                  'nps0912ResultUnavailableReason', ri.result_unavailable_reason,
                                  'nps0912ResultUnavailableOther',  ri.result_unavailable_reason_other
                              )
                              ORDER BY ri.created_at ASC, ri.result_item_text ASC
                          )
                     FROM nps.diagnostic_result_item ri
                    WHERE ri.report_entry_uid = dr.entry_uid
               ),
               '[]'::jsonb
           )                                AS nps_09_result_items_json,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.diagnostic_report dr
      JOIN nps.clinical_entry ce ON ce.entry_uid = dr.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = dr.patient_uid
     WHERE (
           p_include_superseded_or_error = TRUE
           OR (ce.record_lifecycle_status IN ('Active', 'Corrected') AND dr.report_status <> 'Cancelled')
       )
     ORDER BY COALESCE(dr.result_date_time, ce.date_recorded) DESC NULLS LAST,
              dr.report_id ASC;
$$;

-- =============================================================================
-- BLOCK 10: HISTORY OF PROCEDURES EXTRACTION (NPS-10-01 to NPS-10-06)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_procedures(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_10_01_procedure_code         VARCHAR,
    nps_10_01_procedure_text         TEXT,
    nps_10_02_procedure_status       VARCHAR,
    nps_10_03_procedure_date_raw     VARCHAR,
    nps_10_03_procedure_date_time    TIMESTAMPTZ,
    nps_10_04_performing_facility_id VARCHAR,
    nps_10_05_outcome                TEXT,
    nps_10_06_complications          TEXT,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ph.procedure_code                AS nps_10_01_procedure_code,
           ph.procedure_text                AS nps_10_01_procedure_text,
           ph.procedure_status              AS nps_10_02_procedure_status,
           ph.procedure_date_raw            AS nps_10_03_procedure_date_raw,
           ph.procedure_date_time           AS nps_10_03_procedure_date_time,
           ph.performing_facility_id        AS nps_10_04_performing_facility_id,
           ph.outcome                       AS nps_10_05_outcome,
           ph.complications                 AS nps_10_06_complications,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.procedure_history ph
      JOIN nps.clinical_entry ce ON ce.entry_uid = ph.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ph.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY ph.procedure_date_time DESC NULLS LAST,
              ce.clinical_entry_id ASC;
$$;

-- =============================================================================
-- BLOCK 11: MEDICAL DEVICES EXTRACTION (NPS-11-01 to NPS-11-06)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_medical_devices(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_11_01_device_type_code       VARCHAR,
    nps_11_01_device_type_text       TEXT,
    nps_11_02_device_use_status      VARCHAR,
    nps_11_03_date_started_raw       VARCHAR,
    nps_11_03_date_started           DATE,
    nps_11_04_date_stopped_raw       VARCHAR,
    nps_11_04_date_stopped           DATE,
    nps_11_05_body_site              TEXT,
    nps_11_06_device_identifier      TEXT,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           md.device_type_code              AS nps_11_01_device_type_code,
           md.device_type_text              AS nps_11_01_device_type_text,
           md.device_use_status             AS nps_11_02_device_use_status,
           md.date_started_raw              AS nps_11_03_date_started_raw,
           md.date_started                  AS nps_11_03_date_started,
           md.date_stopped_raw              AS nps_11_04_date_stopped_raw,
           md.date_stopped                  AS nps_11_04_date_stopped,
           md.body_site                     AS nps_11_05_body_site,
           md.device_identifier             AS nps_11_06_device_identifier,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.medical_device md
      JOIN nps.clinical_entry ce ON ce.entry_uid = md.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = md.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE md.device_use_status WHEN 'Active' THEN 1 ELSE 2 END,
              md.date_started DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 12: ALERTS EXTRACTION (NPS-12-01 to NPS-12-06)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_clinical_alerts(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_04_09_verification           VARCHAR,
    nps_04_10_original_clinical_code VARCHAR,
    nps_12_01_alert_description      TEXT,
    nps_12_02_alert_category         VARCHAR,
    nps_12_03_alert_status           VARCHAR,
    nps_12_04_alert_source           TEXT,
    nps_12_05_effective_date_raw     VARCHAR,
    nps_12_05_effective_date         DATE,
    nps_12_06_linked_entry_id        VARCHAR,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           ce.verification                  AS nps_04_09_verification,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           ca.alert_description             AS nps_12_01_alert_description,
           ca.alert_category                AS nps_12_02_alert_category,
           ca.alert_status                  AS nps_12_03_alert_status,
           ca.alert_source                  AS nps_12_04_alert_source,
           ca.effective_date_raw            AS nps_12_05_effective_date_raw,
           ca.effective_date                AS nps_12_05_effective_date,
           ca.linked_clinical_entry_id      AS nps_12_06_linked_entry_id,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.clinical_alert ca
      JOIN nps.clinical_entry ce ON ce.entry_uid = ca.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ca.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE ca.alert_status WHEN 'Active' THEN 1 ELSE 2 END,
              ca.effective_date DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 13: ADVANCE DIRECTIVES EXTRACTION (NPS-13-01 to NPS-13-04)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_advance_directives(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_05_event_date_raw         VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_13_01_directive_preference   TEXT,
    nps_13_02_directive_status       VARCHAR,
    nps_13_03_evidence_source        VARCHAR,
    nps_13_03_evidence_source_other  TEXT,
    nps_13_04_date_recorded_raw      VARCHAR,
    nps_13_04_date_recorded          DATE,
    record_lifecycle_status          VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.clinical_event_date_raw       AS nps_04_05_event_date_raw,
           ce.original_recorded_description AS nps_04_06_original_description,
           ad.directive_preference          AS nps_13_01_directive_preference,
           ad.directive_status              AS nps_13_02_directive_status,
           ad.evidence_source               AS nps_13_03_evidence_source,
           ad.evidence_source_other         AS nps_13_03_evidence_source_other,
           ad.date_recorded_raw             AS nps_13_04_date_recorded_raw,
           ad.date_recorded                 AS nps_13_04_date_recorded,
           ce.record_lifecycle_status
      FROM nps.advance_directive ad
      JOIN nps.clinical_entry ce ON ce.entry_uid = ad.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ad.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY ad.date_recorded DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 14: FUNCTIONAL STATUS EXTRACTION (NPS-14-01 to NPS-14-04)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_functional_status(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                            UUID,
    nps_04_01_clinical_entry_id          VARCHAR,
    nps_04_02_source_facility            VARCHAR,
    nps_04_03_source_system              VARCHAR,
    nps_04_04_date_recorded              TIMESTAMPTZ,
    nps_04_06_original_description       TEXT,
    nps_14_01_function_assessed          VARCHAR,
    nps_14_01_function_assessed_other    TEXT,
    nps_14_02_finding_text               TEXT,
    nps_14_02_finding_score              NUMERIC,
    nps_14_03_assessment_date_raw        VARCHAR,
    nps_14_03_assessment_date            DATE,
    nps_14_03_assessment_unknown_reason  TEXT,
    nps_14_04_assistance_needed          TEXT,
    record_lifecycle_status              VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id              AS nps_04_01_clinical_entry_id,
           ce.source_facility_id             AS nps_04_02_source_facility,
           ce.source_system                  AS nps_04_03_source_system,
           ce.date_recorded                  AS nps_04_04_date_recorded,
           ce.original_recorded_description  AS nps_04_06_original_description,
           fs.function_assessed              AS nps_14_01_function_assessed,
           fs.function_assessed_other        AS nps_14_01_function_assessed_other,
           fs.finding_text                   AS nps_14_02_finding_text,
           fs.finding_score                  AS nps_14_02_finding_score,
           fs.assessment_date_raw            AS nps_14_03_assessment_date_raw,
           fs.assessment_date                AS nps_14_03_assessment_date,
           fs.assessment_date_unknown_reason AS nps_14_03_assessment_unknown_reason,
           fs.assistance_needed              AS nps_14_04_assistance_needed,
           ce.record_lifecycle_status
      FROM nps.functional_status fs
      JOIN nps.clinical_entry ce ON ce.entry_uid = fs.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = fs.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY fs.assessment_date DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 15: PREGNANCY HISTORY PLACEHOLDER EXTRACTION (NPS-15-01)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_pregnancy_history_status(
    p_issuing_facility_id VARCHAR,
    p_source_patient_id   VARCHAR,
    p_issuing_system VARCHAR
)
RETURNS TABLE (
    patient_uid                 UUID,
    nps_15_01_governance_status VARCHAR,
    programme_guidance          TEXT
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT tp.patient_uid,
           COALESCE(
               pr.governance_status,
               'Pending approved maternal-health data dictionary'
           )::VARCHAR AS nps_15_01_governance_status,
           'Source document does not define detailed fields; do not invent a dataset'::TEXT AS programme_guidance
      FROM target_patient tp
      LEFT JOIN nps.pregnancy_history_reserved pr ON pr.patient_uid = tp.patient_uid
     WHERE tp.patient_uid IS NOT NULL;
$$;

-- =============================================================================
-- BLOCK 16: SOCIAL HISTORY EXTRACTION (NPS-16-01 to NPS-16-05)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_social_history(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_06_original_description   TEXT,
    nps_16_01_social_history_topic   VARCHAR,
    nps_16_01_topic_other            TEXT,
    nps_16_02_reported_response      TEXT,
    nps_16_03_information_source     VARCHAR,
    nps_16_03_source_other           TEXT,
    nps_16_04_observation_date_raw   VARCHAR,
    nps_16_04_observation_date       DATE,
    nps_16_05_frequency_quantity     TEXT,
    record_lifecycle_status          VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.original_recorded_description AS nps_04_06_original_description,
           sh.social_history_topic          AS nps_16_01_social_history_topic,
           sh.topic_other                   AS nps_16_01_topic_other,
           sh.reported_response             AS nps_16_02_reported_response,
           sh.information_source            AS nps_16_03_information_source,
           sh.information_source_other      AS nps_16_03_source_other,
           sh.observation_date_raw          AS nps_16_04_observation_date_raw,
           sh.observation_date              AS nps_16_04_observation_date,
           sh.frequency_quantity            AS nps_16_05_frequency_quantity,
           ce.record_lifecycle_status
      FROM nps.social_history sh
      JOIN nps.clinical_entry ce ON ce.entry_uid = sh.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = sh.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY sh.observation_date DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 17: CARE PLAN & FOLLOW-UP EXTRACTION (NPS-17-01 to NPS-17-07)
--           Aggregates 0..* planned actions per care plan without fan-out
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_care_plans(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_17_01_care_plan_id           VARCHAR,
    nps_17_02_care_plan_summary      TEXT,
    nps_17_03_plan_status            VARCHAR,
    nps_17_planned_actions_json      JSONB,
    record_lifecycle_status          VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.source_provider_id            AS nps_04_07_source_provider,
           ce.source_encounter_id           AS nps_04_08_source_encounter,
           cp.care_plan_id                  AS nps_17_01_care_plan_id,
           cp.care_plan_summary             AS nps_17_02_care_plan_summary,
           cp.plan_status                   AS nps_17_03_plan_status,
           COALESCE(
               (
                   SELECT jsonb_agg(
                              jsonb_build_object(
                                  'actionUid',                  cpa.action_uid,
                                  'nps1704PlannedActionCategory', cpa.planned_action_category,
                                  'nps1704PlannedActionText',     cpa.planned_action_text,
                                  'nps1705ActionStatus',          cpa.action_status,
                                  'nps1706DueDateRaw',            cpa.due_date_raw,
                                  'nps1706DueDateExact',          cpa.due_date,
                                  'nps1707ReceivingFacilityId',   cpa.receiving_facility_id
                              )
                              ORDER BY cpa.due_date ASC NULLS LAST, cpa.created_at ASC
                          )
                     FROM nps.care_plan_action cpa
                    WHERE cpa.care_plan_entry_uid = cp.entry_uid
               ),
               '[]'::jsonb
           )                                AS nps_17_planned_actions_json,
           ce.record_lifecycle_status
      FROM nps.care_plan cp
      JOIN nps.clinical_entry ce ON ce.entry_uid = cp.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = cp.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY CASE cp.plan_status WHEN 'Active' THEN 1 ELSE 2 END,
              ce.date_recorded DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 18: PAST PROBLEMS EXTRACTION (NPS-18-01 to NPS-18-04)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_past_problems(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_06_original_description   TEXT,
    nps_04_10_original_clinical_code VARCHAR,
    nps_18_01_past_condition_code    VARCHAR,
    nps_18_01_past_condition_text    TEXT,
    nps_18_01_referenced_problem_uid UUID,
    nps_18_02_historical_status      VARCHAR,
    nps_18_03_onset_date_raw         VARCHAR,
    nps_18_03_onset_date             DATE,
    nps_18_03_resolution_date_raw    VARCHAR,
    nps_18_03_resolution_date        DATE,
    nps_18_04_lasting_effects        TEXT,
    record_lifecycle_status          VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.date_recorded                 AS nps_04_04_date_recorded,
           ce.original_recorded_description AS nps_04_06_original_description,
           ce.original_clinical_code        AS nps_04_10_original_clinical_code,
           pp.past_condition_code           AS nps_18_01_past_condition_code,
           pp.past_condition_text           AS nps_18_01_past_condition_text,
           pp.referenced_problem_entry_uid  AS nps_18_01_referenced_problem_uid,
           pp.historical_status             AS nps_18_02_historical_status,
           pp.onset_date_raw                AS nps_18_03_onset_date_raw,
           pp.onset_date                    AS nps_18_03_onset_date,
           pp.resolution_date_raw           AS nps_18_03_resolution_date_raw,
           pp.resolution_date               AS nps_18_03_resolution_date,
           pp.lasting_effects               AS nps_18_04_lasting_effects,
           ce.record_lifecycle_status
      FROM nps.past_problem pp
      JOIN nps.clinical_entry ce ON ce.entry_uid = pp.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = pp.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY pp.resolution_date DESC NULLS LAST,
              pp.onset_date DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 19: PATIENT STORY EXTRACTION (NPS-19-01 to NPS-19-05)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_patient_story(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_06_original_description   TEXT,
    nps_19_01_patient_narrative      TEXT,
    nps_19_02_information_source     VARCHAR,
    nps_19_02_source_other           TEXT,
    nps_19_03_date_recorded_raw      VARCHAR,
    nps_19_03_date_recorded_time     TIMESTAMPTZ,
    nps_19_03_date_unknown_reason    TEXT,
    nps_19_04_language_used          VARCHAR,
    nps_19_04_language_other         VARCHAR,
    nps_19_05_patient_priorities     TEXT,
    record_lifecycle_status          VARCHAR
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id             AS nps_04_01_clinical_entry_id,
           ce.source_facility_id            AS nps_04_02_source_facility,
           ce.source_system                 AS nps_04_03_source_system,
           ce.original_recorded_description AS nps_04_06_original_description,
           ps.patient_narrative             AS nps_19_01_patient_narrative,
           ps.information_source            AS nps_19_02_information_source,
           ps.information_source_other      AS nps_19_02_source_other,
           ps.date_recorded_raw             AS nps_19_03_date_recorded_raw,
           ps.date_recorded_time            AS nps_19_03_date_recorded_time,
           ps.date_recorded_unknown_reason  AS nps_19_03_date_unknown_reason,
           ps.language_used                 AS nps_19_04_language_used,
           ps.language_other                AS nps_19_04_language_other,
           ps.patient_priorities            AS nps_19_05_patient_priorities,
           ce.record_lifecycle_status
      FROM nps.patient_story ps
      JOIN nps.clinical_entry ce ON ce.entry_uid = ps.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = ps.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY ps.date_recorded_time DESC NULLS LAST;
$$;

-- =============================================================================
-- BLOCK 20: VITAL SIGNS EXTRACTION (NPS-20-01 to NPS-20-06)
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.extract_vital_signs(
    p_issuing_facility_id         VARCHAR,
    p_source_patient_id           VARCHAR,
    p_issuing_system VARCHAR,
    p_include_superseded_or_error BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_uid                        UUID,
    nps_04_01_clinical_entry_id      VARCHAR,
    nps_04_02_source_facility        VARCHAR,
    nps_04_03_source_system          VARCHAR,
    nps_04_04_date_recorded          TIMESTAMPTZ,
    nps_04_06_original_description   TEXT,
    nps_04_07_source_provider        VARCHAR,
    nps_04_08_source_encounter       VARCHAR,
    nps_20_01_vital_sign             VARCHAR,
    nps_20_01_vital_sign_other       VARCHAR,
    nps_20_02_value_raw              VARCHAR,
    nps_20_02_value_numeric          NUMERIC,
    nps_20_02_bp_systolic            SMALLINT,
    nps_20_02_bp_diastolic           SMALLINT,
    nps_20_02_value_unknown_reason   TEXT,
    nps_20_03_unit                   VARCHAR,
    nps_20_03_unit_other             VARCHAR,
    nps_20_04_measurement_date_raw   VARCHAR,
    nps_20_04_measurement_date_time  TIMESTAMPTZ,
    nps_20_04_date_unknown_reason    TEXT,
    nps_20_05_body_position          VARCHAR,
    nps_20_06_measurement_method     TEXT,
    record_lifecycle_status          VARCHAR,
    replaces_entry_uid               UUID
)
LANGUAGE sql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    WITH target_patient AS (
        SELECT nps.resolve_patient_uid(p_issuing_facility_id, p_source_patient_id, p_issuing_system) AS patient_uid
    )
    SELECT ce.entry_uid,
           ce.clinical_entry_id                AS nps_04_01_clinical_entry_id,
           ce.source_facility_id               AS nps_04_02_source_facility,
           ce.source_system                    AS nps_04_03_source_system,
           ce.date_recorded                    AS nps_04_04_date_recorded,
           ce.original_recorded_description    AS nps_04_06_original_description,
           ce.source_provider_id               AS nps_04_07_source_provider,
           ce.source_encounter_id              AS nps_04_08_source_encounter,
           vs.vital_sign                       AS nps_20_01_vital_sign,
           vs.vital_sign_other                 AS nps_20_01_vital_sign_other,
           vs.value_raw                        AS nps_20_02_value_raw,
           vs.value_numeric                    AS nps_20_02_value_numeric,
           vs.bp_systolic                      AS nps_20_02_bp_systolic,
           vs.bp_diastolic                     AS nps_20_02_bp_diastolic,
           vs.value_unknown_reason             AS nps_20_02_value_unknown_reason,
           vs.unit                             AS nps_20_03_unit,
           vs.unit_other                       AS nps_20_03_unit_other,
           vs.measurement_date_raw             AS nps_20_04_measurement_date_raw,
           vs.measurement_date_time            AS nps_20_04_measurement_date_time,
           vs.measurement_date_unknown_reason  AS nps_20_04_date_unknown_reason,
           vs.body_position                    AS nps_20_05_body_position,
           vs.measurement_method               AS nps_20_06_measurement_method,
           ce.record_lifecycle_status,
           ce.replaces_entry_uid
      FROM nps.vital_sign vs
      JOIN nps.clinical_entry ce ON ce.entry_uid = vs.entry_uid
      JOIN target_patient tp     ON tp.patient_uid = vs.patient_uid
     WHERE p_include_superseded_or_error = TRUE
        OR ce.record_lifecycle_status IN ('Active', 'Corrected')
     ORDER BY vs.measurement_date_time DESC NULLS LAST,
              vs.vital_sign ASC;
$$;

COMMIT;

