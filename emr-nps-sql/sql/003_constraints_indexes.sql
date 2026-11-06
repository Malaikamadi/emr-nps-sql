-- =============================================================================
-- PROJECT: Sierra Leone EMR National Patient Summary (NPS)
-- FILE:    sql/003_constraints_indexes.sql
-- TARGET:  PostgreSQL 17+
--
-- PURPOSE:
--   Add all relational foreign keys, uniqueness constraints, clinical safety
--   CHECK constraints (NPS-01 through NPS-20), lookup/keyset indexes, and
--   change-sequence triggers to the `nps` schema tables.
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PATIENT & IDENTIFIER CONSTRAINTS (Block 02: NPS-02-01 to NPS-02-15)
-- =============================================================================
ALTER TABLE nps.patient
    ADD CONSTRAINT fk_patient_merged_into
        FOREIGN KEY (merged_into_patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT uq_patient_primary_source
        UNIQUE (primary_source_facility_id, primary_source_system, primary_source_patient_id),
    ADD CONSTRAINT chk_nps_02_01_patient_name
        CHECK (btrim(patient_name) <> ''),
    ADD CONSTRAINT chk_nps_02_02_primary_source
        CHECK (btrim(primary_source_patient_id) <> '' AND btrim(primary_source_facility_id) <> '' AND btrim(primary_source_system) <> ''),
    ADD CONSTRAINT chk_nps_02_04_sex
        CHECK (sex IS NULL OR sex IN ('Male', 'Female', 'Other', 'Unknown')),
    ADD CONSTRAINT chk_nps_02_05_dob_precision
        CHECK (
            date_of_birth_precision IS NULL
            OR date_of_birth_precision IN ('Year', 'Year-Month', 'Full', 'Unknown')
        ),
    ADD CONSTRAINT chk_nps_02_06_age
        CHECK (
            (age_at_assessment_value IS NULL AND age_at_assessment_unit IS NULL)
            OR (
                age_at_assessment_value IS NOT NULL
                AND age_at_assessment_value >= 0
                AND date_of_age_assessment IS NOT NULL
                AND age_at_assessment_unit IS NOT NULL
                AND age_at_assessment_unit IN ('Days', 'Months', 'Years')
            )
        ),
    ADD CONSTRAINT chk_nps_02_08_estimated_dob
        CHECK (
            estimated_birth_date IS NULL
            OR (
                estimated_birth_date IN ('Yes', 'No', 'Unknown')
                AND (date_of_birth_raw IS NOT NULL OR date_of_birth_exact IS NOT NULL)
            )
        ),
    ADD CONSTRAINT chk_nps_02_09_vital_status
        CHECK (vital_status IS NULL OR vital_status IN ('Alive', 'Deceased', 'Unknown')),
    ADD CONSTRAINT chk_nps_02_15_contact_permission
        CHECK (contact_permission IS NULL OR contact_permission IN ('Permitted', 'Restricted', 'Unknown')),
    ADD CONSTRAINT chk_patient_record_status
        CHECK (record_status IN ('Active', 'Inactive', 'Merged', 'Entered in error'));

ALTER TABLE nps.patient_identifier
    ADD CONSTRAINT fk_patient_identifier_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid) ON DELETE CASCADE,
    ADD CONSTRAINT uq_patient_identifier_issuer
        UNIQUE (issuing_facility_id, issuing_system, identifier_type, identifier_value),
    ADD CONSTRAINT chk_nps_02_02_03_element_id
        CHECK (nps_element_id IN ('NPS-02-02', 'NPS-02-03')),
    ADD CONSTRAINT chk_patient_identifier_nonempty
        CHECK (btrim(identifier_value) <> '' AND btrim(issuing_facility_id) <> '' AND btrim(issuing_system) <> ''),
    ADD CONSTRAINT chk_patient_identifier_status
        CHECK (identifier_status IN ('Active', 'Superseded', 'Entered in error'));

ALTER TABLE nps.patient_contact_person
    ADD CONSTRAINT fk_patient_contact_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid) ON DELETE CASCADE,
    ADD CONSTRAINT chk_nps_02_14_contact_name
        CHECK (btrim(contact_name) <> ''),
    ADD CONSTRAINT chk_nps_02_15_person_permission
        CHECK (contact_permission IS NULL OR contact_permission IN ('Permitted', 'Restricted', 'Unknown')),
    ADD CONSTRAINT chk_patient_contact_status
        CHECK (record_status IN ('Active', 'Inactive', 'Entered in error'));

-- =============================================================================
-- 2. SUMMARY DOCUMENT & PROVENANCE CONSTRAINTS (Block 01: NPS-01-01 to NPS-01-17)
-- =============================================================================
ALTER TABLE nps.summary_document
    ADD CONSTRAINT fk_summary_document_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT fk_summary_document_supersedes
        FOREIGN KEY (supersedes_document_uid) REFERENCES nps.summary_document (document_uid),
    ADD CONSTRAINT uq_summary_document_version
        UNIQUE (patient_uid, source_facility_id, source_emr, document_version),
    ADD CONSTRAINT chk_nps_01_02_version_positive
        CHECK (version_number >= 1 AND btrim(document_version) <> ''),
    ADD CONSTRAINT chk_nps_01_07_document_status
        CHECK (document_status IN ('Current', 'Superseded', 'Entered in error')),
    ADD CONSTRAINT chk_nps_01_08_author
        CHECK (
            btrim(author_assembler) <> ''
            AND author_type IN ('Provider', 'Organization', 'Software')
        ),
    ADD CONSTRAINT chk_nps_01_09_generation_method
        CHECK (generation_method IN ('Automated', 'Clinician-reviewed', 'Manual')),
    ADD CONSTRAINT chk_nps_01_10_language
        CHECK (
            language_choice IN ('English', 'Other')
            AND (language_choice <> 'Other' OR (language_other IS NOT NULL AND btrim(language_other) <> ''))
        ),
    ADD CONSTRAINT chk_nps_01_11_confidentiality
        CHECK (confidentiality IN ('Normal', 'Restricted', 'Highly restricted')),
    ADD CONSTRAINT chk_nps_01_12_clinical_period
        CHECK (
            clinical_period_start IS NULL
            OR clinical_period_end IS NULL
            OR clinical_period_end >= clinical_period_start
        ),
    ADD CONSTRAINT chk_nps_01_13_14_attestation
        CHECK (
            (attester IS NULL AND attestation_date_time IS NULL)
            OR (attester IS NOT NULL AND btrim(attester) <> '')
        );

-- At most one 'Current' summary document per patient per source facility
CREATE UNIQUE INDEX IF NOT EXISTS uq_idx_summary_doc_current_per_facility
    ON nps.summary_document (patient_uid, source_facility_id, source_emr)
    WHERE document_status = 'Current';

-- =============================================================================
-- 3. ENCOUNTER & SECTION COMPLETENESS CONSTRAINTS (Block 03: NPS-03-01 to NPS-03-06)
-- =============================================================================
ALTER TABLE nps.clinical_encounter
    ADD CONSTRAINT fk_encounter_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT uq_encounter_source
        UNIQUE (source_facility_id, source_system, source_encounter_id),
    ADD CONSTRAINT chk_encounter_dates
        CHECK (
            encounter_start_time IS NULL
            OR encounter_end_time IS NULL
            OR encounter_end_time >= encounter_start_time
        ),
    ADD CONSTRAINT chk_encounter_status
        CHECK (record_status IN ('Active', 'Corrected', 'Entered in error'));

ALTER TABLE nps.section_completeness
    ADD CONSTRAINT fk_section_completeness_document
        FOREIGN KEY (document_uid) REFERENCES nps.summary_document (document_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_section_completeness_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT fk_section_completeness_block_code
        FOREIGN KEY (nps_block_code) REFERENCES nps.block_catalog (block_code),
    ADD CONSTRAINT fk_section_completeness_block_name
        FOREIGN KEY (nps_block_name) REFERENCES nps.block_catalog (block_name),
    ADD CONSTRAINT uq_section_completeness_doc_block
        UNIQUE (document_uid, nps_block_code),
    ADD CONSTRAINT chk_nps_03_02_info_status
        CHECK (
            section_information_status IN (
                'Entries present',
                'None known',
                'Unknown',
                'Not asked',
                'Not applicable',
                'Withheld'
            )
        ),
    ADD CONSTRAINT chk_nps_03_03_extraction_status
        CHECK (extraction_status IN ('Complete', 'Partial', 'Unsupported', 'Failed')),
    -- CRITICAL SAFETY CONSTRAINT: Missing, unsupported, or failed EMR extraction must NEVER be interpreted as 'None known'
    ADD CONSTRAINT chk_nps_03_failed_never_none_known
        CHECK (
            section_information_status <> 'None known'
            OR (extraction_status = 'Complete' AND NULLIF(btrim(absence_evidence_ref), '') IS NOT NULL)
        ),
    ADD CONSTRAINT chk_nps_03_05_reason_unavailable
        CHECK (
            reason_information_unavailable IS NULL
            OR reason_information_unavailable IN (
                'Not recorded',
                'Not assessed',
                'Source unavailable',
                'Restricted',
                'Other'
            )
        ),
    ADD CONSTRAINT chk_nps_03_06_access_restriction
        CHECK (section_access_restriction IN ('Normal', 'Restricted', 'Withheld'));

-- =============================================================================
-- 4. COMMON CLINICAL ENTRY METADATA CONSTRAINTS (Block 04: NPS-04-01 to NPS-04-10)
-- =============================================================================
ALTER TABLE nps.clinical_entry
    ADD CONSTRAINT fk_clinical_entry_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT fk_clinical_entry_document
        FOREIGN KEY (document_uid) REFERENCES nps.summary_document (document_uid) ON DELETE SET NULL,
    ADD CONSTRAINT fk_clinical_entry_block
        FOREIGN KEY (nps_block_code) REFERENCES nps.block_catalog (block_code),
    ADD CONSTRAINT fk_clinical_entry_encounter
        FOREIGN KEY (encounter_uid) REFERENCES nps.clinical_encounter (encounter_uid) ON DELETE SET NULL,
    ADD CONSTRAINT fk_clinical_entry_replaces
        FOREIGN KEY (replaces_entry_uid) REFERENCES nps.clinical_entry (entry_uid),
    ADD CONSTRAINT uq_clinical_entry_source
        UNIQUE (source_facility_id, source_system, nps_block_code, clinical_entry_id),
    ADD CONSTRAINT chk_nps_04_01_entry_id
        CHECK (btrim(clinical_entry_id) <> '' AND btrim(source_system) <> ''
               AND btrim(source_facility_id) <> '' AND nps_block_code BETWEEN 'NPS-05' AND 'NPS-20'
               AND nps_block_code <> 'NPS-15'),
    ADD CONSTRAINT chk_nps_04_05_precision
        CHECK (
            clinical_event_date_precision IS NULL
            OR clinical_event_date_precision IN ('Year', 'Year-Month', 'Full', 'Timestamp', 'Unknown')
        ),
    ADD CONSTRAINT chk_nps_04_06_description
        CHECK (btrim(original_recorded_description) <> ''),
    ADD CONSTRAINT chk_nps_04_09_verification
        CHECK (verification IS NULL OR verification IN ('Confirmed', 'Suspected', 'Unconfirmed', 'Unknown')),
    ADD CONSTRAINT chk_clinical_entry_lifecycle
        CHECK (record_lifecycle_status IN ('Active', 'Corrected', 'Superseded', 'Entered in error'));

-- =============================================================================
-- 5. CLINICAL SECTION CONSTRAINTS (Blocks NPS-05 through NPS-20)
-- =============================================================================

-- Block 05: Problems & diagnoses
ALTER TABLE nps.problem_diagnosis
    ADD CONSTRAINT fk_problem_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_problem_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_05_01_text
        CHECK (NULLIF(btrim(problem_diagnosis_code), '') IS NOT NULL OR NULLIF(btrim(problem_diagnosis_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_05_02_status
        CHECK (problem_status IN ('Active', 'Resolved', 'Inactive', 'Unknown')),
    ADD CONSTRAINT chk_nps_05_03_certainty
        CHECK (diagnosis_certainty IN ('Confirmed', 'Suspected', 'Unconfirmed', 'Unknown')),
    ADD CONSTRAINT chk_nps_05_04_05_dates
        CHECK (
            onset_date_exact IS NULL
            OR resolution_date_exact IS NULL
            OR resolution_date_exact >= onset_date_exact
        ),
    ADD CONSTRAINT chk_nps_05_06_severity
        CHECK (severity IS NULL OR severity IN ('Mild', 'Moderate', 'Severe', 'Unknown', 'Other')),
    ADD CONSTRAINT chk_nps_05_07_basis
        CHECK (diagnosis_basis IS NULL OR diagnosis_basis IN ('Clinical', 'Laboratory', 'Imaging', 'Patient-reported', 'Unknown'));

-- Block 06: Allergies & intolerances
ALTER TABLE nps.allergy_intolerance
    ADD CONSTRAINT fk_allergy_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_allergy_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_06_01_allergen
        CHECK (NULLIF(btrim(allergen_code), '') IS NOT NULL OR NULLIF(btrim(allergen_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_06_02_status
        CHECK (allergy_status IN ('Active', 'Inactive', 'Resolved', 'Unknown')),
    ADD CONSTRAINT chk_nps_06_03_verification
        CHECK (verification_status IN ('Confirmed', 'Unconfirmed', 'Refuted', 'Unknown')),
    ADD CONSTRAINT chk_nps_06_04_category
        CHECK (allergy_category IS NULL OR allergy_category IN ('Medication', 'Food', 'Environment', 'Other')),
    ADD CONSTRAINT chk_nps_06_06_severity
        CHECK (reaction_severity IS NULL OR reaction_severity IN ('Mild', 'Moderate', 'Severe', 'Unknown')),
    ADD CONSTRAINT chk_nps_06_07_criticality
        CHECK (criticality IS NULL OR criticality IN ('Low', 'High', 'Unable to assess'));

-- Block 07: Medication summary
ALTER TABLE nps.medication_summary
    ADD CONSTRAINT fk_medication_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_medication_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_07_01_medicine
        CHECK (NULLIF(btrim(medicine_code), '') IS NOT NULL OR NULLIF(btrim(medicine_name), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_07_02_status
        CHECK (medication_status IN ('Active', 'Completed', 'Stopped', 'Unknown')),
    ADD CONSTRAINT chk_nps_07_03_evidence
        CHECK (evidence_of_use IN ('Prescribed', 'Dispensed', 'Administered', 'Patient-reported', 'Unknown')),
    ADD CONSTRAINT chk_nps_07_06_route
        CHECK (route IS NULL OR btrim(route) <> ''),
    ADD CONSTRAINT chk_nps_07_08_09_dates
        CHECK (start_date IS NULL OR end_date IS NULL OR end_date >= start_date);

-- Block 08: Immunizations
ALTER TABLE nps.immunization
    ADD CONSTRAINT fk_immunization_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_immunization_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_08_01_vaccine
        CHECK (NULLIF(btrim(vaccine_code), '') IS NOT NULL OR NULLIF(btrim(vaccine_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_08_02_status
        CHECK (administration_status IN ('Given', 'Not given', 'Unknown')),
    ADD CONSTRAINT chk_nps_08_03_date_administered
        CHECK (
            btrim(date_administered_raw) <> ''
            AND (
                date_administered_raw <> 'Unknown'
                OR (date_administered_unknown_reason IS NOT NULL AND btrim(date_administered_unknown_reason) <> '')
            )
        ),
    ADD CONSTRAINT chk_nps_08_06_evidence_source
        CHECK (evidence_source IS NULL OR evidence_source IN ('EMR', 'Vaccination card', 'Patient/caregiver report', 'Other'));

-- Block 09: Laboratory & imaging results (Report + Result Items)
ALTER TABLE nps.diagnostic_report
    ADD CONSTRAINT fk_diag_report_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_diag_report_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_09_01_report_id
        CHECK (btrim(report_id) <> ''),
    ADD CONSTRAINT chk_nps_09_02_report_type
        CHECK (report_type IN ('Laboratory', 'Imaging', 'Other')),
    ADD CONSTRAINT chk_nps_09_03_test_text
        CHECK (NULLIF(btrim(test_or_study_code), '') IS NOT NULL OR NULLIF(btrim(test_or_study_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_09_04_report_status
        CHECK (report_status IN ('Preliminary', 'Final', 'Corrected', 'Cancelled'));

ALTER TABLE nps.diagnostic_result_item
    ADD CONSTRAINT fk_diag_item_report
        FOREIGN KEY (report_entry_uid) REFERENCES nps.diagnostic_report (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_diag_item_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_09_05_item_text
        CHECK (NULLIF(btrim(result_item_code), '') IS NOT NULL OR NULLIF(btrim(result_item_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_09_06_choice
        CHECK (
            result_value_choice IS NULL
            OR result_value_choice IN ('Positive', 'Negative', 'Reactive', 'Non-reactive')
        ),
    ADD CONSTRAINT chk_nps_09_12_unavailable_reason
        CHECK (
            result_unavailable_reason IS NULL
            OR result_unavailable_reason IN ('Pending', 'Not recorded', 'Withheld', 'Other')
        ),
    ADD CONSTRAINT chk_nps_09_06_12_value_or_reason
        CHECK (
            num_nonnulls(result_value_numeric, result_value_choice,
                NULLIF(btrim(result_value_narrative), ''), result_unavailable_reason) >= 1
            AND (result_unavailable_reason IS NULL OR
                 num_nonnulls(result_value_numeric, result_value_choice,
                              NULLIF(btrim(result_value_narrative), '')) = 0)
            AND (numeric_result_is_dimensional IS DISTINCT FROM TRUE OR
                 (result_value_numeric IS NOT NULL AND NULLIF(btrim(result_unit), '') IS NOT NULL))
        );

-- Block 10: History of procedures
ALTER TABLE nps.procedure_history
    ADD CONSTRAINT fk_procedure_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_procedure_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_10_01_procedure
        CHECK (NULLIF(btrim(procedure_code), '') IS NOT NULL OR NULLIF(btrim(procedure_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_10_02_status
        CHECK (procedure_status IN ('Completed', 'In progress', 'Not done', 'Unknown'));

-- Block 11: Medical devices
ALTER TABLE nps.medical_device
    ADD CONSTRAINT fk_device_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_device_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_11_01_device_type
        CHECK (NULLIF(btrim(device_type_code), '') IS NOT NULL OR NULLIF(btrim(device_type_text), '') IS NOT NULL),
    ADD CONSTRAINT chk_nps_11_02_status
        CHECK (device_use_status IN ('Active', 'Stopped', 'Completed', 'Unknown')),
    ADD CONSTRAINT chk_nps_11_03_04_dates
        CHECK (date_started IS NULL OR date_stopped IS NULL OR date_stopped >= date_started);

-- Block 12: Alerts
ALTER TABLE nps.clinical_alert
    ADD CONSTRAINT fk_alert_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_alert_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT fk_alert_linked_entry
        FOREIGN KEY (linked_entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE SET NULL,
    ADD CONSTRAINT chk_nps_12_01_description
        CHECK (btrim(alert_description) <> ''),
    ADD CONSTRAINT chk_nps_12_02_category
        CHECK (alert_category IN ('Clinical', 'Infection prevention', 'Safety', 'Other')),
    ADD CONSTRAINT chk_nps_12_03_status
        CHECK (alert_status IN ('Active', 'Inactive', 'Resolved', 'Unknown')),
    ADD CONSTRAINT chk_nps_12_04_source
        CHECK (btrim(alert_source) <> '');

-- Block 13: Advance directives
ALTER TABLE nps.advance_directive
    ADD CONSTRAINT fk_directive_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_directive_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_13_01_preference
        CHECK (btrim(directive_preference) <> ''),
    ADD CONSTRAINT chk_nps_13_02_status
        CHECK (directive_status IN ('Active', 'Superseded', 'Withdrawn', 'Unknown')),
    ADD CONSTRAINT chk_nps_13_03_source
        CHECK (evidence_source IN ('Patient statement', 'Clinical document', 'Legal document', 'Other'));

-- Block 14: Functional status
ALTER TABLE nps.functional_status
    ADD CONSTRAINT fk_functional_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_functional_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_14_01_domain
        CHECK (function_assessed IN ('Mobility', 'Self-care', 'Communication', 'Other')),
    ADD CONSTRAINT chk_nps_14_02_finding
        CHECK (btrim(finding_text) <> ''),
    ADD CONSTRAINT chk_nps_14_03_assessment_date
        CHECK (
            btrim(assessment_date_raw) <> ''
            AND (
                assessment_date_raw <> 'Unknown'
                OR (assessment_date_unknown_reason IS NOT NULL AND btrim(assessment_date_unknown_reason) <> '')
            )
        );

-- Block 15: Pregnancy history (Reserved placeholder)
ALTER TABLE nps.pregnancy_history_reserved
    ADD CONSTRAINT fk_pregnancy_reserved_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid) ON DELETE CASCADE,
    ADD CONSTRAINT chk_nps_15_01_governance_status
        CHECK (governance_status = 'Pending approved maternal-health data dictionary');

-- Block 16: Social history
ALTER TABLE nps.social_history
    ADD CONSTRAINT fk_social_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_social_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_16_01_topic
        CHECK (social_history_topic IN ('Tobacco', 'Alcohol', 'Other relevant topic')),
    ADD CONSTRAINT chk_nps_16_02_response
        CHECK (btrim(reported_response) <> ''),
    ADD CONSTRAINT chk_nps_16_03_source
        CHECK (information_source IN ('Patient', 'Caregiver', 'Clinician', 'Other'));

-- Block 17: Care plan & follow-up
ALTER TABLE nps.care_plan
    ADD CONSTRAINT fk_care_plan_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_care_plan_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_17_01_plan_id
        CHECK (btrim(care_plan_id) <> ''),
    ADD CONSTRAINT chk_nps_17_02_summary
        CHECK (btrim(care_plan_summary) <> ''),
    ADD CONSTRAINT chk_nps_17_03_status
        CHECK (plan_status IN ('Active', 'Completed', 'Cancelled', 'Unknown'));

ALTER TABLE nps.care_plan_action
    ADD CONSTRAINT fk_care_plan_action_plan
        FOREIGN KEY (care_plan_entry_uid) REFERENCES nps.care_plan (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_care_plan_action_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_17_04_action_category
        CHECK (planned_action_category IN ('Review', 'Referral', 'Investigation', 'Other')),
    ADD CONSTRAINT chk_nps_17_04_action_text
        CHECK (btrim(planned_action_text) <> ''),
    ADD CONSTRAINT chk_nps_17_05_action_status
        CHECK (action_status IN ('Pending', 'In progress', 'Completed', 'Cancelled'));

-- Block 18: Past problems
ALTER TABLE nps.past_problem
    ADD CONSTRAINT fk_past_problem_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_past_problem_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT fk_past_problem_referenced
        FOREIGN KEY (referenced_problem_entry_uid) REFERENCES nps.problem_diagnosis (entry_uid) ON DELETE SET NULL,
    ADD CONSTRAINT chk_nps_18_01_condition
        CHECK (NULLIF(btrim(past_condition_code), '') IS NOT NULL OR NULLIF(btrim(past_condition_text), '') IS NOT NULL),
    -- Explicitly prohibits 'Active' status in Past Problems (NPS-18-02 guidance)
    ADD CONSTRAINT chk_nps_18_02_historical_status
        CHECK (historical_status IN ('Resolved', 'Inactive', 'Unknown'));

-- Block 19: Patient story
ALTER TABLE nps.patient_story
    ADD CONSTRAINT fk_patient_story_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_patient_story_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_19_01_narrative
        CHECK (btrim(patient_narrative) <> ''),
    ADD CONSTRAINT chk_nps_19_02_source
        CHECK (information_source IN ('Patient', 'Caregiver', 'Other')),
    ADD CONSTRAINT chk_nps_19_03_date_recorded
        CHECK (
            btrim(date_recorded_raw) <> ''
            AND (
                date_recorded_raw <> 'Unknown'
                OR (date_recorded_unknown_reason IS NOT NULL AND btrim(date_recorded_unknown_reason) <> '')
            )
        ),
    ADD CONSTRAINT chk_nps_19_04_language
        CHECK (
            language_used IN ('English', 'Krio', 'Other')
            AND (language_used <> 'Other' OR (language_other IS NOT NULL AND btrim(language_other) <> ''))
        );

-- Block 20: Vital signs
ALTER TABLE nps.vital_sign
    ADD CONSTRAINT fk_vital_sign_entry
        FOREIGN KEY (entry_uid) REFERENCES nps.clinical_entry (entry_uid) ON DELETE CASCADE,
    ADD CONSTRAINT fk_vital_sign_patient
        FOREIGN KEY (patient_uid) REFERENCES nps.patient (patient_uid),
    ADD CONSTRAINT chk_nps_20_01_vital_sign
        CHECK (
            vital_sign IN ('BP', 'Pulse', 'Respiratory rate', 'Temperature', 'SpO2', 'Weight', 'Height', 'Other')
            AND (vital_sign <> 'Other' OR (vital_sign_other IS NOT NULL AND btrim(vital_sign_other) <> ''))
        ),
    -- NPS-20-02: BP requires both systolic and diastolic values (unless Unknown with reason)
    ADD CONSTRAINT chk_nps_20_02_value
        CHECK (
            btrim(value_raw) <> ''
            AND (
                (value_raw = 'Unknown' AND value_unknown_reason IS NOT NULL AND btrim(value_unknown_reason) <> '')
                OR (vital_sign = 'BP' AND bp_systolic IS NOT NULL AND bp_diastolic IS NOT NULL AND bp_systolic > 0 AND bp_diastolic > 0)
                OR (vital_sign <> 'BP' AND value_raw <> 'Unknown')
            )
        ),
    ADD CONSTRAINT chk_nps_20_03_unit
        CHECK (unit IN ('mmHg', 'beats/min', 'breaths/min', '°C', '%', 'kg', 'cm', 'Other', 'Not applicable')),
    ADD CONSTRAINT chk_nps_20_04_measurement_date
        CHECK (
            btrim(measurement_date_raw) <> ''
            AND (
                measurement_date_raw <> 'Unknown'
                OR (measurement_date_unknown_reason IS NOT NULL AND btrim(measurement_date_unknown_reason) <> '')
            )
        ),
    ADD CONSTRAINT chk_nps_20_05_body_position
        CHECK (body_position IS NULL OR body_position IN ('Sitting', 'Standing', 'Lying', 'Unknown'));

-- =============================================================================
-- 6. PATIENT AND CLINICAL LOOKUP INDEXES
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_nps_patient_mpi
    ON nps.patient (mpi_patient_id)
    WHERE mpi_patient_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_nps_patient_primary_source
    ON nps.patient (primary_source_facility_id, primary_source_patient_id);

CREATE INDEX IF NOT EXISTS idx_nps_patient_identifier_lookup
    ON nps.patient_identifier (issuing_facility_id, identifier_value, identifier_status);

CREATE INDEX IF NOT EXISTS idx_nps_patient_identifier_patient
    ON nps.patient_identifier (patient_uid, nps_element_id);

CREATE INDEX IF NOT EXISTS idx_nps_contact_person_patient
    ON nps.patient_contact_person (patient_uid, record_status);

CREATE INDEX IF NOT EXISTS idx_nps_summary_doc_patient_status
    ON nps.summary_document (patient_uid, document_status, generated_date_time DESC);

CREATE INDEX IF NOT EXISTS idx_nps_section_completeness_doc
    ON nps.section_completeness (document_uid, nps_block_code);

CREATE INDEX IF NOT EXISTS idx_nps_clinical_entry_patient_block
    ON nps.clinical_entry (patient_uid, nps_block_code, record_lifecycle_status);

CREATE INDEX IF NOT EXISTS idx_nps_diag_result_item_report
    ON nps.diagnostic_result_item (report_entry_uid);

CREATE INDEX IF NOT EXISTS idx_nps_care_plan_action_plan
    ON nps.care_plan_action (care_plan_entry_uid);




-- =============================================================================
-- 8. ATTACH UPDATED_AT & CHANGE_SEQ TRIGGERS
-- =============================================================================
CREATE OR REPLACE TRIGGER trg_patient_touch
    BEFORE INSERT OR UPDATE ON nps.patient
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_patient_identifier_touch
    BEFORE INSERT OR UPDATE ON nps.patient_identifier
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_patient_contact_person_touch
    BEFORE INSERT OR UPDATE ON nps.patient_contact_person
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_summary_document_touch
    BEFORE INSERT OR UPDATE ON nps.summary_document
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_clinical_encounter_touch
    BEFORE INSERT OR UPDATE ON nps.clinical_encounter
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_section_completeness_touch
    BEFORE INSERT OR UPDATE ON nps.section_completeness
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_clinical_entry_touch
    BEFORE INSERT OR UPDATE ON nps.clinical_entry
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_problem_diagnosis_touch
    BEFORE INSERT OR UPDATE ON nps.problem_diagnosis
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_allergy_intolerance_touch
    BEFORE INSERT OR UPDATE ON nps.allergy_intolerance
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_medication_summary_touch
    BEFORE INSERT OR UPDATE ON nps.medication_summary
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_immunization_touch
    BEFORE INSERT OR UPDATE ON nps.immunization
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_diagnostic_report_touch
    BEFORE INSERT OR UPDATE ON nps.diagnostic_report
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_diagnostic_result_item_touch
    BEFORE INSERT OR UPDATE ON nps.diagnostic_result_item
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_procedure_history_touch
    BEFORE INSERT OR UPDATE ON nps.procedure_history
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_medical_device_touch
    BEFORE INSERT OR UPDATE ON nps.medical_device
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_clinical_alert_touch
    BEFORE INSERT OR UPDATE ON nps.clinical_alert
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_advance_directive_touch
    BEFORE INSERT OR UPDATE ON nps.advance_directive
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_functional_status_touch
    BEFORE INSERT OR UPDATE ON nps.functional_status
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_pregnancy_history_reserved_touch
    BEFORE INSERT OR UPDATE ON nps.pregnancy_history_reserved
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_social_history_touch
    BEFORE INSERT OR UPDATE ON nps.social_history
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_care_plan_touch
    BEFORE INSERT OR UPDATE ON nps.care_plan
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_care_plan_action_touch
    BEFORE INSERT OR UPDATE ON nps.care_plan_action
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_past_problem_touch
    BEFORE INSERT OR UPDATE ON nps.past_problem
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_patient_story_touch
    BEFORE INSERT OR UPDATE ON nps.patient_story
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();

CREATE OR REPLACE TRIGGER trg_vital_sign_touch
    BEFORE INSERT OR UPDATE ON nps.vital_sign
    FOR EACH ROW EXECUTE FUNCTION nps.trg_set_updated_and_change_seq();


-- A child can link only to a parent for the same patient. Typed entries must also
-- match their NPS block so one source entry cannot appear in multiple sections.
ALTER TABLE nps.summary_document
    ADD UNIQUE (document_uid, patient_uid),
    ADD UNIQUE (patient_uid, source_facility_id, source_emr, version_number),
    ADD UNIQUE (document_uid, patient_uid, source_facility_id, source_emr),
    ADD FOREIGN KEY (supersedes_document_uid, patient_uid, source_facility_id, source_emr)
        REFERENCES nps.summary_document (document_uid, patient_uid, source_facility_id, source_emr),
    ADD CHECK (document_uid IS DISTINCT FROM supersedes_document_uid),
    ADD CHECK (btrim(document_id) <> '' AND btrim(shared_patient_id) <> ''
        AND btrim(source_facility_id) <> '' AND btrim(source_emr) <> '');
ALTER TABLE nps.clinical_encounter
    ADD UNIQUE (encounter_uid, patient_uid),
    ADD CHECK (btrim(source_encounter_id) <> '' AND btrim(source_facility_id) <> ''
        AND btrim(source_system) <> '');
ALTER TABLE nps.block_catalog ADD UNIQUE (block_code, block_name);
ALTER TABLE nps.section_completeness
    ADD FOREIGN KEY (document_uid, patient_uid) REFERENCES nps.summary_document (document_uid, patient_uid),
    ADD FOREIGN KEY (nps_block_code, nps_block_name) REFERENCES nps.block_catalog (block_code, block_name),
    ADD CHECK (nps_block_code BETWEEN 'NPS-05' AND 'NPS-20');
ALTER TABLE nps.clinical_entry
    ADD UNIQUE (entry_uid, patient_uid),
    ADD UNIQUE (entry_uid, patient_uid, nps_block_code),
    ADD FOREIGN KEY (document_uid, patient_uid) REFERENCES nps.summary_document (document_uid, patient_uid),
    ADD FOREIGN KEY (encounter_uid, patient_uid) REFERENCES nps.clinical_encounter (encounter_uid, patient_uid),
    ADD FOREIGN KEY (replaces_entry_uid, patient_uid, nps_block_code)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code),
    ADD CHECK (entry_uid IS DISTINCT FROM replaces_entry_uid);
ALTER TABLE nps.patient ADD CHECK (
    patient_uid IS DISTINCT FROM merged_into_patient_uid
    AND ((record_status = 'Merged') = (merged_into_patient_uid IS NOT NULL))
);
ALTER TABLE nps.problem_diagnosis
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-05') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.allergy_intolerance
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-06') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.medication_summary
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-07') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.immunization
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-08') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.diagnostic_report
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-09') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.procedure_history
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-10') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.medical_device
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-11') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.clinical_alert
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-12') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.advance_directive
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-13') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.functional_status
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-14') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.social_history
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-16') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.care_plan
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-17') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.past_problem
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-18') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.patient_story
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-19') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);
ALTER TABLE nps.vital_sign
    ADD COLUMN entry_block VARCHAR(16) GENERATED ALWAYS AS ('NPS-20') STORED,
    ADD FOREIGN KEY (entry_uid, patient_uid, entry_block)
        REFERENCES nps.clinical_entry (entry_uid, patient_uid, nps_block_code);

ALTER TABLE nps.diagnostic_report ADD UNIQUE (entry_uid, patient_uid);
ALTER TABLE nps.diagnostic_result_item ADD FOREIGN KEY (report_entry_uid, patient_uid)
    REFERENCES nps.diagnostic_report (entry_uid, patient_uid);
ALTER TABLE nps.care_plan ADD UNIQUE (entry_uid, patient_uid);
ALTER TABLE nps.care_plan_action ADD FOREIGN KEY (care_plan_entry_uid, patient_uid)
    REFERENCES nps.care_plan (entry_uid, patient_uid);
ALTER TABLE nps.problem_diagnosis ADD UNIQUE (entry_uid, patient_uid);
ALTER TABLE nps.past_problem ADD FOREIGN KEY (referenced_problem_entry_uid, patient_uid)
    REFERENCES nps.problem_diagnosis (entry_uid, patient_uid);
ALTER TABLE nps.clinical_alert ADD FOREIGN KEY (linked_entry_uid, patient_uid)
    REFERENCES nps.clinical_entry (entry_uid, patient_uid);


CREATE UNIQUE INDEX one_live_correction_per_predecessor
    ON nps.clinical_entry (replaces_entry_uid)
    WHERE record_lifecycle_status IN ('Active', 'Corrected') AND replaces_entry_uid IS NOT NULL;
ALTER TABLE nps.diagnostic_result_item ADD UNIQUE (report_entry_uid, source_item_id);
ALTER TABLE nps.care_plan_action ADD UNIQUE (care_plan_entry_uid, source_action_id);
ALTER TABLE nps.vital_sign ADD CHECK (
    vital_sign = 'Other' OR value_raw = 'Unknown'
    OR (unit IS NOT NULL AND unit <> 'Not applicable')
);

COMMIT;

