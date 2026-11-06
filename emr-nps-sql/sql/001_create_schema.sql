-- =============================================================================
-- PROJECT: Sierra Leone EMR National Patient Summary (NPS)
-- FILE:    sql/001_create_schema.sql
-- TARGET:  PostgreSQL 17+
--
-- PURPOSE:
--   1. Create the dedicated `nps` reference schema (isolated from native EMR tables).
--   2. Create the monotonic change-tracking sequence `nps.sync_change_seq` for
--      offline-first keyset incremental synchronisation.
--   3. Create and seed the official NPS Block Catalog (`nps.block_catalog`, 20 blocks)
--      and Data Dictionary Element Registry (`nps.data_dictionary_element`, 149 elements)
--      for full traceability to `NPS_Data_Dictionary_Updated.xlsx`.
--   4. Create common trigger helper functions for modification timestamps and
--      monotonic change sequence assignment.
-- =============================================================================

BEGIN;

CREATE SCHEMA nps;

COMMENT ON SCHEMA nps IS
    'Proposed Sierra Leone National Patient Summary (NPS) Pre-FHIR reference schema (Blocks NPS-01 to NPS-20). Independent of native facility EMR tables.';

-- =============================================================================
-- 1. MONOTONIC CHANGE SEQUENCE FOR OFFLINE-FIRST SYNCHRONISATION
-- =============================================================================
CREATE SEQUENCE IF NOT EXISTS nps.sync_change_seq
    AS BIGINT
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;

COMMENT ON SEQUENCE nps.sync_change_seq IS
    'Local change stamp. Use the separate ordered outbox protocol for reliable transfer, since sequence values alone do not establish commit order.';

-- =============================================================================
-- 2. NPS BLOCK CATALOG (20 Blocks: NPS-01 through NPS-20)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.block_catalog (
    block_code          VARCHAR(16)  PRIMARY KEY,
    block_name          VARCHAR(100) NOT NULL UNIQUE,
    priority_level      VARCHAR(40)  NOT NULL,
    element_count       SMALLINT     NOT NULL,
    is_clinical_section BOOLEAN      NOT NULL DEFAULT TRUE,
    implementation_note TEXT         NOT NULL,
    CONSTRAINT chk_block_catalog_priority CHECK (
        priority_level IN (
            'Core',
            'Required',
            'Recommended',
            'Optional',
            'Optional - pending approval'
        )
    ),
    CONSTRAINT chk_block_catalog_element_count CHECK (element_count > 0)
);

COMMENT ON TABLE nps.block_catalog IS
    'Master catalog of the 20 Sierra Leone NPS blocks, priority levels, expected element counts, and governance notes.';

INSERT INTO nps.block_catalog (block_code, block_name, priority_level, element_count, is_clinical_section, implementation_note)
VALUES
    ('NPS-01', 'Document & provenance',        'Core',                        17, FALSE, 'Programme review / national value-set validation'),
    ('NPS-02', 'Patient & contacts',           'Core',                        15, FALSE, 'Programme review / national value-set validation'),
    ('NPS-03', 'Section completeness',         'Core',                         6, FALSE, 'Programme review / national value-set validation'),
    ('NPS-04', 'Common clinical metadata',     'Core',                        10, FALSE, 'Programme review / national value-set validation'),
    ('NPS-05', 'Problems & diagnoses',         'Required',                     8, TRUE,  'Programme review / national value-set validation'),
    ('NPS-06', 'Allergies & intolerances',     'Required',                     8, TRUE,  'Programme review / national value-set validation'),
    ('NPS-07', 'Medication summary',           'Required',                    11, TRUE,  'Programme review / national value-set validation'),
    ('NPS-08', 'Immunizations',                'Recommended',                  8, TRUE,  'Programme review / national value-set validation'),
    ('NPS-09', 'Laboratory & imaging results', 'Recommended',                 12, TRUE,  'Programme review / national value-set validation'),
    ('NPS-10', 'History of procedures',        'Recommended',                  6, TRUE,  'Programme review / national value-set validation'),
    ('NPS-11', 'Medical devices',              'Recommended',                  6, TRUE,  'Programme review / national value-set validation'),
    ('NPS-12', 'Alerts',                       'Recommended',                  6, TRUE,  'Programme review / national value-set validation'),
    ('NPS-13', 'Advance directives',           'Optional',                     4, TRUE,  'Programme review / national value-set validation'),
    ('NPS-14', 'Functional status',            'Optional',                     4, TRUE,  'Programme review / national value-set validation'),
    ('NPS-15', 'Pregnancy history',            'Optional - pending approval',  1, TRUE,  'Pregnancy history pending separate approval'),
    ('NPS-16', 'Social history',               'Optional',                     5, TRUE,  'Programme review / national value-set validation'),
    ('NPS-17', 'Care plan & follow-up',        'Optional',                     7, TRUE,  'Programme review / national value-set validation'),
    ('NPS-18', 'Past problems',                'Optional',                     4, TRUE,  'Programme review / national value-set validation'),
    ('NPS-19', 'Patient story',                'Optional',                     5, TRUE,  'Programme review / national value-set validation'),
    ('NPS-20', 'Vital signs',                  'Optional',                     6, TRUE,  'Programme review / national value-set validation')
ON CONFLICT (block_code) DO UPDATE
SET block_name          = EXCLUDED.block_name,
    priority_level      = EXCLUDED.priority_level,
    element_count       = EXCLUDED.element_count,
    is_clinical_section = EXCLUDED.is_clinical_section,
    implementation_note = EXCLUDED.implementation_note;

-- =============================================================================
-- 3. DATA DICTIONARY ELEMENT REGISTRY (All 149 Elements: NPS-01-01 to NPS-20-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.data_dictionary_element (
    element_id         VARCHAR(16)  PRIMARY KEY,
    block_code         VARCHAR(16)  NOT NULL REFERENCES nps.block_catalog (block_code),
    element_name       VARCHAR(120) NOT NULL,
    definition         TEXT         NOT NULL,
    dictionary_type    VARCHAR(64)  NOT NULL,
    permitted_values   TEXT         NOT NULL,
    requirement_code   VARCHAR(8)   NOT NULL,
    programme_guidance TEXT         NOT NULL,
    target_table       VARCHAR(100) NOT NULL,
    target_columns     TEXT         NOT NULL,
    CONSTRAINT chk_dd_element_requirement CHECK (
        requirement_code IN ('M', 'K', 'O', '—')
    )
);

COMMENT ON TABLE nps.data_dictionary_element IS
    'Complete 149-element metadata registry extracted verbatim from NPS_Data_Dictionary_Updated.xlsx with traceability to target nps tables and columns.';

INSERT INTO nps.data_dictionary_element (
    element_id, block_code, element_name, definition, dictionary_type,
    permitted_values, requirement_code, programme_guidance, target_table, target_columns
)
VALUES
    -- Block 01: Document & provenance (17 elements)
    ('NPS-01-01', 'NPS-01', 'Document ID', 'Unique NPS document identifier', 'Identifier', 'System-generated unique ID', 'M', 'One per summary version', 'nps.summary_document', 'document_id'),
    ('NPS-01-02', 'NPS-01', 'Document version', 'Version of this summary', 'Text', '1, 2, 3…', 'M', 'Retain earlier versions', 'nps.summary_document', 'document_version, version_number'),
    ('NPS-01-03', 'NPS-01', 'Patient ID', 'Shared client identifier', 'Identifier', 'MPI/shared ID; issuer-qualified facility ID if pending', 'M', 'Do not require national ID', 'nps.summary_document', 'shared_patient_id'),
    ('NPS-01-04', 'NPS-01', 'Source facility ID', 'Facility where source data originated', 'Identifier', 'Health Facility Registry ID; approved temporary ID', 'M', 'Identify issuer', 'nps.summary_document', 'source_facility_id'),
    ('NPS-01-05', 'NPS-01', 'Source EMR', 'System providing information', 'Text', 'Approved EMR system list', 'M', 'Retain source name', 'nps.summary_document', 'source_emr'),
    ('NPS-01-06', 'NPS-01', 'Generated date/time', 'When NPS was assembled', 'Date and time', 'Recorded timestamp with timezone', 'M', 'Not the clinical event date', 'nps.summary_document', 'generated_date_time'),
    ('NPS-01-07', 'NPS-01', 'Document status', 'Status of summary', 'Single choice', 'Current; Superseded; Entered in error', 'M', 'Never overwrite previous version', 'nps.summary_document', 'document_status'),
    ('NPS-01-08', 'NPS-01', 'Author/assembler', 'Person, organization or software that created NPS', 'Identifier/text', 'Provider ID; organization ID; software name', 'M', 'Do not invent clinician sign-off', 'nps.summary_document', 'author_assembler'),
    ('NPS-01-09', 'NPS-01', 'Generation method', 'How summary was created', 'Single choice', 'Automated; Clinician-reviewed; Manual', 'M', 'Different from attestation', 'nps.summary_document', 'generation_method'),
    ('NPS-01-10', 'NPS-01', 'Language', 'Language of summary', 'Single choice', 'English; Other (specify)', 'M', 'Use approved language list', 'nps.summary_document', 'language_choice, language_other'),
    ('NPS-01-11', 'NPS-01', 'Confidentiality', 'Overall sharing restriction', 'Single choice', 'Normal; Restricted; Highly restricted', 'M', 'Enforce approved access policy', 'nps.summary_document', 'confidentiality'),
    ('NPS-01-12', 'NPS-01', 'Clinical period', 'Period covered by source records', 'Date range', 'Start date; End date', 'K', 'May differ from generation date', 'nps.summary_document', 'clinical_period_start, clinical_period_end'),
    ('NPS-01-13', 'NPS-01', 'Attester', 'Person confirming summary accuracy', 'Identifier/text', 'Provider ID; Name', 'O', 'Only when actually attested', 'nps.summary_document', 'attester'),
    ('NPS-01-14', 'NPS-01', 'Attestation date', 'When summary was confirmed', 'Date and time', 'Recorded timestamp', 'O', 'Do not infer from extraction', 'nps.summary_document', 'attestation_date_time'),
    ('NPS-01-15', 'NPS-01', 'Custodian', 'Organization responsible for document', 'Identifier/text', 'Organization ID and name', 'O', 'Not necessarily database host', 'nps.summary_document', 'custodian'),
    ('NPS-01-16', 'NPS-01', 'Received date/time', 'When SHR received the summary', 'Date and time', 'Recorded timestamp', 'M', 'System recorded', 'nps.summary_document', 'received_date_time'),
    ('NPS-01-17', 'NPS-01', 'Source record reference', 'Reference to originating record', 'Identifier', 'Source document or encounter ID', 'K', 'Supports traceability', 'nps.summary_document', 'source_record_reference'),
    ('NPS-02-01', 'NPS-02', 'Patient name', 'Name as recorded in EMR', 'Text', 'Free text', 'M', 'Do not require surname', 'nps.patient', 'patient_name'),
    ('NPS-02-02', 'NPS-02', 'Source patient identifier', 'Patient ID used in source facility', 'Identifier', 'Facility MRN plus issuing facility', 'M', 'At least one source ID', 'nps.patient / nps.patient_identifier', 'primary_source_patient_id, primary_source_facility_id'),
    ('NPS-02-03', 'NPS-02', 'Other patient identifiers', 'Additional identifiers', 'Identifier', 'National ID; immunization ID; other issuer-qualified IDs', 'K', 'Never mandatory national ID', 'nps.patient_identifier', 'identifier_type, identifier_value, issuing_facility_id'),
    ('NPS-02-04', 'NPS-02', 'Sex', 'Recorded sex', 'Single choice', 'Male; Female; Other; Unknown', 'K', 'Preserve source value', 'nps.patient', 'sex'),
    ('NPS-02-05', 'NPS-02', 'Date of birth', 'Birth date if known', 'Date', 'Full or partial date', 'K', 'Do not invent missing month/day', 'nps.patient', 'date_of_birth_raw, date_of_birth_exact, date_of_birth_precision'),
    ('NPS-02-06', 'NPS-02', 'Age at assessment', 'Age if DOB unknown', 'Number + unit', 'Days; Months; Years', 'K', 'Capture age-as-of date', 'nps.patient', 'age_at_assessment_value, age_at_assessment_unit'),
    ('NPS-02-07', 'NPS-02', 'Date of age assessment', 'Date age was recorded', 'Date', 'Recorded date', 'K', 'Needed for interpreting age', 'nps.patient', 'date_of_age_assessment'),
    ('NPS-02-08', 'NPS-02', 'Estimated birth date?', 'Whether DOB was estimated', 'Yes/No/Unknown', 'Yes; No; Unknown', 'K', 'Only if DOB supplied', 'nps.patient', 'estimated_birth_date'),
    ('NPS-02-09', 'NPS-02', 'Vital status', 'Whether person is alive', 'Single choice', 'Alive; Deceased; Unknown', 'K', 'Do not infer', 'nps.patient', 'vital_status'),
    ('NPS-02-10', 'NPS-02', 'Phone number', 'Patient contact number', 'Text', 'Phone number; Not available', 'O', 'Access restricted', 'nps.patient', 'phone_number'),
    ('NPS-02-11', 'NPS-02', 'District', 'District of residence', 'Single choice', 'Approved district list', 'K', 'If recorded', 'nps.patient', 'district'),
    ('NPS-02-12', 'NPS-02', 'Chiefdom', 'Chiefdom of residence', 'Single choice', 'Approved chiefdom list', 'O', 'If recorded', 'nps.patient', 'chiefdom'),
    ('NPS-02-13', 'NPS-02', 'Locality', 'Town or community', 'Text', 'Free text', 'O', 'Do not require street address', 'nps.patient', 'locality'),
    ('NPS-02-14', 'NPS-02', 'Emergency contact', 'Named contact and relationship', 'Text', 'Name; Relationship; Phone', 'O', 'Not automatically legal representative', 'nps.patient_contact_person', 'contact_name, relationship, phone_number'),
    ('NPS-02-15', 'NPS-02', 'Contact permission', 'Whether contact may be used', 'Single choice', 'Permitted; Restricted; Unknown', 'O', 'Do not assume permission', 'nps.patient', 'contact_permission'),
    ('NPS-03-01', 'NPS-03', 'NPS block', 'Clinical section being reported', 'Single choice', 'Problems; Allergies; Medications; etc.', 'M', 'One status per block', 'nps.section_completeness', 'nps_block_code, nps_block_name'),
    ('NPS-03-02', 'NPS-03', 'Section information status', 'Whether clinical information is available', 'Single choice', 'Entries present; None known; Unknown; Not asked; Not applicable; Withheld', 'M', 'None known requires supporting evidence', 'nps.section_completeness', 'section_information_status, absence_evidence_ref'),
    ('NPS-03-03', 'NPS-03', 'Extraction status', 'Whether source section was successfully obtained', 'Single choice', 'Complete; Partial; Unsupported; Failed', 'M', 'Failed does not mean none known', 'nps.section_completeness', 'extraction_status'),
    ('NPS-03-04', 'NPS-03', 'Last assessed date', 'When section was clinically assessed', 'Date', 'Recorded date', 'K', 'If known', 'nps.section_completeness', 'last_assessed_date'),
    ('NPS-03-05', 'NPS-03', 'Reason information unavailable', 'Why data are missing', 'Single choice', 'Not recorded; Not assessed; Source unavailable; Restricted; Other', 'K', 'Use when relevant', 'nps.section_completeness', 'reason_information_unavailable, reason_unavailable_other'),
    ('NPS-03-06', 'NPS-03', 'Section access restriction', 'Section-specific sharing control', 'Single choice', 'Normal; Restricted; Withheld', 'K', 'Distinct from absence', 'nps.section_completeness', 'section_access_restriction'),
    ('NPS-04-01', 'NPS-04', 'Clinical entry ID', 'Identifier of individual clinical entry', 'Identifier', 'Source record ID or governed surrogate', 'M', 'Each recorded entry', 'nps.clinical_entry', 'clinical_entry_id'),
    ('NPS-04-02', 'NPS-04', 'Source facility', 'Facility recording clinical entry', 'Identifier', 'Facility ID', 'M', 'May differ from NPS author', 'nps.clinical_entry', 'source_facility_id'),
    ('NPS-04-03', 'NPS-04', 'Source system', 'EMR containing clinical entry', 'Text', 'EMR name/ID', 'M', 'Retain provenance', 'nps.clinical_entry', 'source_system'),
    ('NPS-04-04', 'NPS-04', 'Date recorded', 'When source documented the entry', 'Date and time', 'Recorded date/time', 'K', 'Different from event date', 'nps.clinical_entry', 'date_recorded'),
    ('NPS-04-05', 'NPS-04', 'Clinical event date', 'When event occurred', 'Date or date/time', 'Full/partial date; Unknown', 'K', 'Retain date precision', 'nps.clinical_entry', 'clinical_event_date_raw, clinical_event_timestamp, clinical_event_date_precision'),
    ('NPS-04-06', 'NPS-04', 'Original recorded description', 'Unchanged source clinical wording', 'Text', 'Free text', 'M', 'Preserve original meaning', 'nps.clinical_entry', 'original_recorded_description'),
    ('NPS-04-07', 'NPS-04', 'Source provider', 'Provider who recorded entry', 'Identifier', 'Provider ID; Unknown', 'K', 'If captured', 'nps.clinical_entry', 'source_provider_id'),
    ('NPS-04-08', 'NPS-04', 'Source encounter', 'Linked consultation/visit', 'Identifier', 'Encounter ID', 'K', 'If available', 'nps.clinical_entry', 'source_encounter_id, encounter_uid'),
    ('NPS-04-09', 'NPS-04', 'Verification', 'How reliably entry is established', 'Single choice', 'Confirmed; Suspected; Unconfirmed; Unknown', 'K', 'Where applicable', 'nps.clinical_entry', 'verification'),
    ('NPS-04-10', 'NPS-04', 'Original clinical code', 'Code recorded by source system', 'Code/text', 'Local code; ICD; SNOMED CT; other', 'K', 'Do not invent mapping', 'nps.clinical_entry', 'original_clinical_code, original_code_system'),
    ('NPS-05-01', 'NPS-05', 'Problem or diagnosis', 'Clinically relevant condition', 'Code or text', 'Approved diagnosis list; Free text if uncoded', 'M', 'Per recorded condition', 'nps.problem_diagnosis', 'problem_diagnosis_code, problem_diagnosis_text'),
    ('NPS-05-02', 'NPS-05', 'Problem status', 'Whether condition is ongoing', 'Single choice', 'Active; Resolved; Inactive; Unknown', 'M', 'Do not assume resolved', 'nps.problem_diagnosis', 'problem_status'),
    ('NPS-05-03', 'NPS-05', 'Diagnosis certainty', 'Certainty of diagnosis', 'Single choice', 'Confirmed; Suspected; Unconfirmed; Unknown', 'M', 'Preserve provisional diagnosis', 'nps.problem_diagnosis', 'diagnosis_certainty'),
    ('NPS-05-04', 'NPS-05', 'Onset date', 'When condition began', 'Date', 'Recorded full/partial date', 'K', 'Do not estimate', 'nps.problem_diagnosis', 'onset_date_raw, onset_date_exact'),
    ('NPS-05-05', 'NPS-05', 'Resolution date', 'When condition ended', 'Date', 'Recorded date', 'K', 'Only if known', 'nps.problem_diagnosis', 'resolution_date_raw, resolution_date_exact'),
    ('NPS-05-06', 'NPS-05', 'Severity', 'Documented severity', 'Single choice/text', 'Mild; Moderate; Severe; Unknown; Other', 'K', 'No inferred grading', 'nps.problem_diagnosis', 'severity, severity_other'),
    ('NPS-05-07', 'NPS-05', 'Diagnosis basis', 'Evidence supporting diagnosis', 'Single choice', 'Clinical; Laboratory; Imaging; Patient-reported; Unknown', 'K', 'If recorded', 'nps.problem_diagnosis', 'diagnosis_basis'),
    ('NPS-05-08', 'NPS-05', 'Management note', 'Brief relevant treatment/follow-up context', 'Text', 'Free text', 'O', 'Avoid copying full note', 'nps.problem_diagnosis', 'management_note'),
    ('NPS-06-01', 'NPS-06', 'Allergen', 'Substance or agent involved', 'Code or text', 'Medicine; Food; Environmental; Other; Unknown agent', 'M', 'Per recorded allergy', 'nps.allergy_intolerance', 'allergen_code, allergen_text'),
    ('NPS-06-02', 'NPS-06', 'Allergy status', 'Whether allergy is current', 'Single choice', 'Active; Inactive; Resolved; Unknown', 'M', 'Not recorded ≠ none known', 'nps.allergy_intolerance', 'allergy_status'),
    ('NPS-06-03', 'NPS-06', 'Verification status', 'Certainty of allergy record', 'Single choice', 'Confirmed; Unconfirmed; Refuted; Unknown', 'M', 'Preserve uncertainty', 'nps.allergy_intolerance', 'verification_status'),
    ('NPS-06-04', 'NPS-06', 'Allergy category', 'Type of agent', 'Single choice', 'Medication; Food; Environment; Other', 'K', 'If recorded', 'nps.allergy_intolerance', 'allergy_category'),
    ('NPS-06-05', 'NPS-06', 'Reaction', 'Clinical reaction experienced', 'Code or text', 'Rash; Breathing difficulty; Other (specify)', 'K', 'Do not infer from adverse event', 'nps.allergy_intolerance', 'reaction_code, reaction_text'),
    ('NPS-06-06', 'NPS-06', 'Reaction severity', 'Severity of observed reaction', 'Single choice', 'Mild; Moderate; Severe; Unknown', 'K', 'Different from future risk', 'nps.allergy_intolerance', 'reaction_severity'),
    ('NPS-06-07', 'NPS-06', 'Criticality', 'Potential seriousness of future exposure', 'Single choice', 'Low; High; Unable to assess', 'K', 'If assessed', 'nps.allergy_intolerance', 'criticality'),
    ('NPS-06-08', 'NPS-06', 'First noted date', 'Date allergy first recorded', 'Date', 'Recorded date', 'K', 'If available', 'nps.allergy_intolerance', 'first_noted_date_raw, first_noted_date'),
    ('NPS-07-01', 'NPS-07', 'Medicine', 'Medicine name', 'Code or text', 'National formulary/generic list; Free text', 'M', 'Per recorded medication', 'nps.medication_summary', 'medicine_code, medicine_name'),
    ('NPS-07-02', 'NPS-07', 'Medication status', 'Current medication-use status', 'Single choice', 'Active; Completed; Stopped; Unknown', 'M', 'Do not infer active from prescription', 'nps.medication_summary', 'medication_status'),
    ('NPS-07-03', 'NPS-07', 'Evidence of use', 'Source of medication information', 'Single choice', 'Prescribed; Dispensed; Administered; Patient-reported; Unknown', 'M', 'Prescription ≠ confirmed use', 'nps.medication_summary', 'evidence_of_use'),
    ('NPS-07-04', 'NPS-07', 'Strength', 'Product strength', 'Text', 'e.g., 500 mg tablet', 'K', 'Separate from dose', 'nps.medication_summary', 'strength'),
    ('NPS-07-05', 'NPS-07', 'Dose', 'Amount per administration', 'Number + unit/text', 'e.g., 1 tablet; 5 mL', 'K', 'Keep complex instructions verbatim', 'nps.medication_summary', 'dose_value, dose_unit, dose_text'),
    ('NPS-07-06', 'NPS-07', 'Route', 'How medicine is taken', 'Single choice', 'Oral; Intravenous; Intramuscular; Topical; Other', 'K', 'National list', 'nps.medication_summary', 'route, route_other'),
    ('NPS-07-07', 'NPS-07', 'Frequency', 'How often medicine is taken', 'Text/choice', 'Once daily; Twice daily; As needed; Other', 'K', 'Do not infer', 'nps.medication_summary', 'frequency'),
    ('NPS-07-08', 'NPS-07', 'Start date', 'Medication start date', 'Date', 'Recorded date', 'K', 'If known', 'nps.medication_summary', 'start_date_raw, start_date'),
    ('NPS-07-09', 'NPS-07', 'End date', 'Medication end date', 'Date', 'Recorded date', 'K', 'If known', 'nps.medication_summary', 'end_date_raw, end_date'),
    ('NPS-07-10', 'NPS-07', 'Reason for use', 'Condition or indication', 'Code or text', 'Diagnosis; Free text', 'K', 'If documented', 'nps.medication_summary', 'reason_for_use_code, reason_for_use_text'),
    ('NPS-07-11', 'NPS-07', 'Prescriber', 'Provider responsible for prescription', 'Identifier', 'Provider ID', 'K', 'If available', 'nps.medication_summary', 'prescriber_id'),
    ('NPS-08-01', 'NPS-08', 'Vaccine', 'Vaccine administered or recorded', 'Code or text', 'National EPI vaccine list; Other', 'M', 'Per immunization event', 'nps.immunization', 'vaccine_code, vaccine_text'),
    ('NPS-08-02', 'NPS-08', 'Administration status', 'Whether vaccine was given', 'Single choice', 'Given; Not given; Unknown', 'M', 'Scheduled dose ≠ administered', 'nps.immunization', 'administration_status'),
    ('NPS-08-03', 'NPS-08', 'Date administered', 'Date vaccination occurred', 'Date', 'Full/partial date; Unknown with reason', 'M', 'Do not fabricate date', 'nps.immunization', 'date_administered_raw, date_administered_exact, date_administered_unknown_reason'),
    ('NPS-08-04', 'NPS-08', 'Dose number', 'Dose within schedule', 'Text/number', '1; 2; 3; Booster; Other', 'K', 'If known', 'nps.immunization', 'dose_number'),
    ('NPS-08-05', 'NPS-08', 'Vaccine batch', 'Batch/lot number', 'Text', 'As recorded', 'K', 'If known', 'nps.immunization', 'vaccine_batch'),
    ('NPS-08-06', 'NPS-08', 'Evidence source', 'Where vaccination information came from', 'Single choice', 'EMR; Vaccination card; Patient/caregiver report; Other', 'K', 'Preserve provenance', 'nps.immunization', 'evidence_source, evidence_source_other'),
    ('NPS-08-07', 'NPS-08', 'Administering facility', 'Facility giving vaccine', 'Identifier', 'Facility ID', 'K', 'If known', 'nps.immunization', 'administering_facility_id'),
    ('NPS-08-08', 'NPS-08', 'Next dose due', 'Next planned vaccination date', 'Date', 'Recorded date', 'O', 'Not evidence of completed dose', 'nps.immunization', 'next_dose_due_date'),
    ('NPS-09-01', 'NPS-09', 'Report ID', 'Identifier for test report', 'Identifier', 'Lab/imaging report ID', 'M', 'One per report', 'nps.diagnostic_report', 'report_id'),
    ('NPS-09-02', 'NPS-09', 'Report type', 'Kind of diagnostic report', 'Single choice', 'Laboratory; Imaging; Other', 'M', 'Report level', 'nps.diagnostic_report', 'report_type'),
    ('NPS-09-03', 'NPS-09', 'Test or study', 'Test or imaging examination', 'Code or text', 'National test list; Free text', 'M', 'Report level', 'nps.diagnostic_report', 'test_or_study_code, test_or_study_text'),
    ('NPS-09-04', 'NPS-09', 'Report status', 'Status of result', 'Single choice', 'Preliminary; Final; Corrected; Cancelled', 'M', 'Keep corrections', 'nps.diagnostic_report', 'report_status'),
    ('NPS-09-05', 'NPS-09', 'Result item', 'Analyte or observation name', 'Code or text', 'Hb; Malaria RDT; HIV test; Other', 'M', 'Per reported observation', 'nps.diagnostic_result_item', 'result_item_code, result_item_text'),
    ('NPS-09-06', 'NPS-09', 'Result value', 'Recorded finding', 'Number/text/choice', 'Numeric; Positive; Negative; Reactive; Non-reactive; Narrative', 'M', 'May be unavailable with reason', 'nps.diagnostic_result_item', 'result_value_numeric, result_value_choice, result_value_narrative'),
    ('NPS-09-07', 'NPS-09', 'Result unit', 'Unit of measurement', 'Text', 'g/dL; mmol/L; Other', 'K', 'Required for numeric dimensional results', 'nps.diagnostic_result_item', 'result_unit, numeric_result_is_dimensional'),
    ('NPS-09-08', 'NPS-09', 'Result date', 'When test/result applies', 'Date and time', 'Recorded date/time', 'K', 'Do not use extract time', 'nps.diagnostic_report / nps.diagnostic_result_item', 'result_date_time'),
    ('NPS-09-09', 'NPS-09', 'Reference range', 'Applicable laboratory reference', 'Text/number', 'Low–High; Narrative', 'K', 'If provided', 'nps.diagnostic_result_item', 'reference_range'),
    ('NPS-09-10', 'NPS-09', 'Interpretation', 'Interpretation documented by laboratory', 'Text/choice', 'High; Low; Normal; Abnormal; Narrative', 'K', 'Do not auto-interpret', 'nps.diagnostic_result_item', 'interpretation'),
    ('NPS-09-11', 'NPS-09', 'Imaging conclusion', 'Radiology/imaging impression', 'Text', 'Brief narrative', 'K', 'For imaging', 'nps.diagnostic_report', 'imaging_conclusion'),
    ('NPS-09-12', 'NPS-09', 'Result unavailable reason', 'Why result value absent', 'Single choice', 'Pending; Not recorded; Withheld; Other', 'K', 'Distinguish from negative', 'nps.diagnostic_result_item', 'result_unavailable_reason, result_unavailable_reason_other'),
    ('NPS-10-01', 'NPS-10', 'Procedure', 'Significant clinical procedure', 'Code or text', 'Approved procedure list; Free text', 'M', 'Per procedure', 'nps.procedure_history', 'procedure_code, procedure_text'),
    ('NPS-10-02', 'NPS-10', 'Procedure status', 'Whether procedure occurred', 'Single choice', 'Completed; In progress; Not done; Unknown', 'M', 'Order ≠ completed procedure', 'nps.procedure_history', 'procedure_status'),
    ('NPS-10-03', 'NPS-10', 'Procedure date', 'When performed', 'Date or date/time', 'Full/partial date', 'K', 'If recorded', 'nps.procedure_history', 'procedure_date_raw, procedure_date_time'),
    ('NPS-10-04', 'NPS-10', 'Performing facility', 'Facility where performed', 'Identifier', 'Facility ID', 'K', 'If known', 'nps.procedure_history', 'performing_facility_id'),
    ('NPS-10-05', 'NPS-10', 'Outcome', 'Documented result of procedure', 'Text', 'Free text', 'K', 'Do not infer', 'nps.procedure_history', 'outcome'),
    ('NPS-10-06', 'NPS-10', 'Complications', 'Documented complications', 'Text', 'Free text; None documented', 'K', 'Only if assessed', 'nps.procedure_history', 'complications'),
    ('NPS-11-01', 'NPS-11', 'Device type', 'Implanted or clinically relevant assistive device', 'Code or text', 'Pacemaker; Implant; Prosthesis; Other', 'M', 'Exclude routine facility equipment', 'nps.medical_device', 'device_type_code, device_type_text'),
    ('NPS-11-02', 'NPS-11', 'Device use status', 'Whether device is currently used', 'Single choice', 'Active; Stopped; Completed; Unknown', 'M', 'Unknown removal ≠ active', 'nps.medical_device', 'device_use_status'),
    ('NPS-11-03', 'NPS-11', 'Date inserted/started', 'Start of device use', 'Date', 'Recorded date', 'K', 'If known', 'nps.medical_device', 'date_started_raw, date_started'),
    ('NPS-11-04', 'NPS-11', 'Date removed/stopped', 'End of device use', 'Date', 'Recorded date', 'K', 'If known', 'nps.medical_device', 'date_stopped_raw, date_stopped'),
    ('NPS-11-05', 'NPS-11', 'Body site', 'Where device is used', 'Text', 'Free text', 'K', 'If relevant', 'nps.medical_device', 'body_site'),
    ('NPS-11-06', 'NPS-11', 'Device identifier', 'Device model or recorded identifier', 'Text', 'Model; Serial number if available', 'O', 'Not required for legacy records', 'nps.medical_device', 'device_identifier'),
    ('NPS-12-01', 'NPS-12', 'Alert description', 'Clinically important recorded warning', 'Text', 'Free text', 'M', 'Only explicitly documented alerts', 'nps.clinical_alert', 'alert_description'),
    ('NPS-12-02', 'NPS-12', 'Alert category', 'Nature of alert', 'Single choice', 'Clinical; Infection prevention; Safety; Other', 'M', 'Nationally governed categories', 'nps.clinical_alert', 'alert_category'),
    ('NPS-12-03', 'NPS-12', 'Alert status', 'Whether alert remains applicable', 'Single choice', 'Active; Inactive; Resolved; Unknown', 'M', 'No automatic inference', 'nps.clinical_alert', 'alert_status'),
    ('NPS-12-04', 'NPS-12', 'Alert source', 'Person/system recording alert', 'Identifier/text', 'Provider ID; Facility; Source system', 'M', 'Traceable provenance', 'nps.clinical_alert', 'alert_source'),
    ('NPS-12-05', 'NPS-12', 'Effective date', 'When alert applies', 'Date', 'Recorded date', 'K', 'If known', 'nps.clinical_alert', 'effective_date_raw, effective_date'),
    ('NPS-12-06', 'NPS-12', 'Linked clinical entry', 'Related allergy/problem if any', 'Identifier', 'Clinical entry ID', 'O', 'Avoid contradictory duplicates', 'nps.clinical_alert', 'linked_entry_uid, linked_clinical_entry_id'),
    ('NPS-13-01', 'NPS-13', 'Directive or preference', 'Documented care preference or directive', 'Text', 'Free text', 'M', 'Only when documented', 'nps.advance_directive', 'directive_preference'),
    ('NPS-13-02', 'NPS-13', 'Directive status', 'Status of documented preference', 'Single choice', 'Active; Superseded; Withdrawn; Unknown', 'M', 'Legal validity requires separate review', 'nps.advance_directive', 'directive_status'),
    ('NPS-13-03', 'NPS-13', 'Evidence source', 'Origin of directive', 'Single choice', 'Patient statement; Clinical document; Legal document; Other', 'M', 'Do not assume legal effect', 'nps.advance_directive', 'evidence_source, evidence_source_other'),
    ('NPS-13-04', 'NPS-13', 'Date recorded', 'When recorded', 'Date', 'Recorded date', 'K', 'If available', 'nps.advance_directive', 'date_recorded_raw, date_recorded'),
    ('NPS-14-01', 'NPS-14', 'Function assessed', 'Domain assessed', 'Single choice/text', 'Mobility; Self-care; Communication; Other', 'M', 'Per assessment', 'nps.functional_status', 'function_assessed, function_assessed_other'),
    ('NPS-14-02', 'NPS-14', 'Finding', 'Documented functional ability', 'Text/number', 'Independent; Needs assistance; Narrative; Score', 'M', 'No inference from diagnosis', 'nps.functional_status', 'finding_text, finding_score'),
    ('NPS-14-03', 'NPS-14', 'Assessment date', 'When assessed', 'Date', 'Recorded date; Unknown with reason', 'M', 'Preserve timing', 'nps.functional_status', 'assessment_date_raw, assessment_date, assessment_date_unknown_reason'),
    ('NPS-14-04', 'NPS-14', 'Assistance needed', 'Help or support required', 'Text', 'Free text', 'K', 'If documented', 'nps.functional_status', 'assistance_needed'),
    ('NPS-15-01', 'NPS-15', 'Pregnancy history block', 'Reserved maternal health section', 'Not yet defined', 'Pending approved maternal-health data dictionary', '—', 'Source document does not define detailed fields; do not invent a dataset', 'nps.pregnancy_history_reserved', 'governance_status'),
    ('NPS-16-01', 'NPS-16', 'Social history topic', 'Topic recorded', 'Single choice', 'Tobacco; Alcohol; Other relevant topic', 'M', 'Per observation', 'nps.social_history', 'social_history_topic, topic_other'),
    ('NPS-16-02', 'NPS-16', 'Reported response', 'Patient-reported status or quantity', 'Text/choice/number', 'Current; Former; Never; Unknown; Other', 'M', 'Unknown ≠ never', 'nps.social_history', 'reported_response'),
    ('NPS-16-03', 'NPS-16', 'Information source', 'Who provided information', 'Single choice', 'Patient; Caregiver; Clinician; Other', 'M', 'If recorded', 'nps.social_history', 'information_source, information_source_other'),
    ('NPS-16-04', 'NPS-16', 'Observation date', 'When history was obtained', 'Date', 'Recorded date', 'K', 'If available', 'nps.social_history', 'observation_date_raw, observation_date'),
    ('NPS-16-05', 'NPS-16', 'Frequency/quantity', 'Amount or frequency reported', 'Text/number + unit', 'As recorded', 'K', 'No inference', 'nps.social_history', 'frequency_quantity'),
    ('NPS-17-01', 'NPS-17', 'Care plan ID', 'Identifier of documented care plan', 'Identifier', 'Plan ID', 'M', 'Per existing plan', 'nps.care_plan', 'care_plan_id'),
    ('NPS-17-02', 'NPS-17', 'Care plan summary', 'Documented plan or instructions', 'Text', 'Free text', 'M', 'Do not generate treatment advice', 'nps.care_plan', 'care_plan_summary'),
    ('NPS-17-03', 'NPS-17', 'Plan status', 'Progress of plan', 'Single choice', 'Active; Completed; Cancelled; Unknown', 'M', 'If recorded', 'nps.care_plan', 'plan_status'),
    ('NPS-17-04', 'NPS-17', 'Planned action', 'Specific follow-up or referral activity', 'Text', 'Review; Referral; Investigation; Other', 'K', 'Only if recorded', 'nps.care_plan_action', 'planned_action_category, planned_action_text'),
    ('NPS-17-05', 'NPS-17', 'Action status', 'Progress of planned action', 'Single choice', 'Pending; In progress; Completed; Cancelled', 'K', 'If action recorded', 'nps.care_plan_action', 'action_status'),
    ('NPS-17-06', 'NPS-17', 'Due date', 'Date action is expected', 'Date', 'Recorded date', 'K', 'If recorded', 'nps.care_plan_action', 'due_date_raw, due_date'),
    ('NPS-17-07', 'NPS-17', 'Receiving facility', 'Referral destination', 'Identifier', 'Facility ID', 'K', 'If applicable', 'nps.care_plan_action', 'receiving_facility_id'),
    ('NPS-18-01', 'NPS-18', 'Past condition', 'Previously relevant health condition', 'Code or text', 'Approved diagnosis list; Free text', 'M', 'Reference existing problem where possible', 'nps.past_problem', 'past_condition_code, past_condition_text, referenced_problem_entry_uid'),
    ('NPS-18-02', 'NPS-18', 'Historical status', 'Past condition status', 'Single choice', 'Resolved; Inactive; Unknown', 'M', 'Do not duplicate active problems', 'nps.past_problem', 'historical_status'),
    ('NPS-18-03', 'NPS-18', 'Onset/resolution', 'When condition began or resolved', 'Date/date range', 'Recorded date(s)', 'K', 'If known', 'nps.past_problem', 'onset_date_raw, onset_date, resolution_date_raw, resolution_date'),
    ('NPS-18-04', 'NPS-18', 'Lasting effects', 'Clinically relevant sequelae', 'Text', 'Free text', 'K', 'If documented', 'nps.past_problem', 'lasting_effects'),
    ('NPS-19-01', 'NPS-19', 'Patient narrative', 'Patient-attributed clinical context', 'Text', 'Brief free text', 'M', 'Do not turn narrative into diagnosis', 'nps.patient_story', 'patient_narrative'),
    ('NPS-19-02', 'NPS-19', 'Information source', 'Who provided the story', 'Single choice/text', 'Patient; Caregiver; Other', 'M', 'Attribution required', 'nps.patient_story', 'information_source, information_source_other'),
    ('NPS-19-03', 'NPS-19', 'Date recorded', 'When narrative was recorded', 'Date or date/time', 'Recorded date; Unknown with reason', 'M', 'If known', 'nps.patient_story', 'date_recorded_raw, date_recorded_time, date_recorded_unknown_reason'),
    ('NPS-19-04', 'NPS-19', 'Language', 'Language used for story', 'Single choice', 'English; Krio; Other (specify)', 'M', 'Preserve original wording', 'nps.patient_story', 'language_used, language_other'),
    ('NPS-19-05', 'NPS-19', 'Patient priorities', 'Patient-stated concerns or goals', 'Text', 'Free text', 'K', 'If documented', 'nps.patient_story', 'patient_priorities'),
    ('NPS-20-01', 'NPS-20', 'Vital sign', 'Measurement being recorded', 'Single choice', 'BP; Pulse; Respiratory rate; Temperature; SpO2; Weight; Height; Other', 'M', 'Per measurement', 'nps.vital_sign', 'vital_sign, vital_sign_other'),
    ('NPS-20-02', 'NPS-20', 'Value', 'Measured value', 'Number/text', 'Recorded value; Unknown with reason', 'M', 'BP requires systolic and diastolic values', 'nps.vital_sign', 'value_raw, value_numeric, bp_systolic, bp_diastolic, value_unknown_reason'),
    ('NPS-20-03', 'NPS-20', 'Unit', 'Unit for measurement', 'Single choice', 'mmHg; beats/min; breaths/min; °C; %; kg; cm', 'M', 'Required for dimensional numbers', 'nps.vital_sign', 'unit, unit_other'),
    ('NPS-20-04', 'NPS-20', 'Measurement date', 'When measured', 'Date and time', 'Recorded date/time; Unknown with reason', 'M', 'Not NPS generation date', 'nps.vital_sign', 'measurement_date_raw, measurement_date_time, measurement_date_unknown_reason'),
    ('NPS-20-05', 'NPS-20', 'Body position', 'Position at measurement', 'Single choice', 'Sitting; Standing; Lying; Unknown', 'K', 'If relevant', 'nps.vital_sign', 'body_position'),
    ('NPS-20-06', 'NPS-20', 'Measurement method', 'How measurement obtained', 'Text', 'Free text', 'O', 'If available', 'nps.vital_sign', 'measurement_method')
ON CONFLICT (element_id) DO UPDATE
SET block_code         = EXCLUDED.block_code,
    element_name       = EXCLUDED.element_name,
    definition         = EXCLUDED.definition,
    dictionary_type    = EXCLUDED.dictionary_type,
    permitted_values   = EXCLUDED.permitted_values,
    requirement_code   = EXCLUDED.requirement_code,
    programme_guidance = EXCLUDED.programme_guidance,
    target_table       = EXCLUDED.target_table,
    target_columns     = EXCLUDED.target_columns;

-- =============================================================================
-- 4. COMMON TRIGGER FUNCTION FOR UPDATED_AT & MONOTONIC CHANGE_SEQ
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.trg_set_updated_and_change_seq()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.created_at := COALESCE(NEW.created_at, CURRENT_TIMESTAMP);
        NEW.updated_at := COALESCE(NEW.updated_at, CURRENT_TIMESTAMP);
        NEW.change_seq := nextval('nps.sync_change_seq');
    ELSIF TG_OP = 'UPDATE' THEN
        NEW.created_at := OLD.created_at;
        NEW.updated_at := CURRENT_TIMESTAMP;
        NEW.change_seq := nextval('nps.sync_change_seq');
    END IF;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION nps.trg_set_updated_and_change_seq() IS
    'Automatically stamps updated_at and increments the monotonic change_seq on every INSERT or UPDATE for offline sync tracking.';

COMMIT;
