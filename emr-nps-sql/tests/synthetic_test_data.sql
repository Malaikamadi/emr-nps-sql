-- Fictional fixtures for an isolated test database only.
BEGIN;
SET LOCAL ROLE nps_ingest;

INSERT INTO nps.patient (
    patient_uid, primary_source_facility_id, primary_source_system, primary_source_patient_id,
    patient_name, date_of_birth_raw, date_of_birth_precision, phone_number, contact_permission
) VALUES
('00000000-0000-4000-8000-000000000001', 'TEST-F01', 'TEST-EMR', 'LOCAL-1',
 'Synthetic Patient One', '1999-03', 'Year-Month', '+00000000001', 'Restricted'),
('00000000-0000-4000-8000-000000000002', 'TEST-F01', 'TEST-LEGACY', 'LOCAL-1',
 'Synthetic Patient Two', NULL, NULL, NULL, NULL),
('00000000-0000-4000-8000-000000000003', 'TEST-F02', 'TEST-EMR', 'LOCAL-1',
 'Synthetic Patient Three', NULL, NULL, NULL, NULL);

INSERT INTO nps.patient_identifier (patient_uid, nps_element_id, issuing_facility_id,
    issuing_system, identifier_type, identifier_value)
VALUES ('00000000-0000-4000-8000-000000000001', 'NPS-02-02', 'TEST-F01',
        'TEST-EMR', 'MRN', 'LOCAL-ALIAS'),
       ('00000000-0000-4000-8000-000000000001', 'NPS-02-03', 'TEST-F01',
        'TEST-REGISTRY', 'Other', 'SYNTHETIC-SECONDARY-ID');

INSERT INTO nps.patient_contact_person (patient_uid, contact_name, relationship, phone_number)
VALUES ('00000000-0000-4000-8000-000000000001', 'Synthetic Contact One', 'Sibling', '+00000000002'),
       ('00000000-0000-4000-8000-000000000001', 'Synthetic Contact Two', 'Friend', NULL);

INSERT INTO nps.clinical_encounter (
    encounter_uid, patient_uid, source_facility_id, source_system, source_encounter_id, encounter_start_time
) VALUES
('00000000-0000-4000-8000-000000000011', '00000000-0000-4000-8000-000000000001',
 'TEST-F01', 'TEST-EMR', 'TEST-VISIT-1', '2025-01-02 08:00+00'),
('00000000-0000-4000-8000-000000000012', '00000000-0000-4000-8000-000000000001',
 'TEST-F01', 'TEST-EMR', 'TEST-VISIT-2', '2025-01-03 08:00+00');

INSERT INTO nps.summary_document (
    document_uid, patient_uid, document_id, document_version, version_number, shared_patient_id,
    source_facility_id, source_emr, generated_date_time, document_status, author_assembler,
    generation_method, language_choice, confidentiality
) VALUES
('00000000-0000-4000-8000-000000000021', '00000000-0000-4000-8000-000000000001',
 'SYNTHETIC-DOC-1', '1', 1, 'TEST-MPI-1', 'TEST-F01', 'TEST-EMR', '2025-01-05 09:00+00',
 'Current', 'Synthetic test builder', 'Automated', 'English', 'Normal'),
('00000000-0000-4000-8000-000000000022', '00000000-0000-4000-8000-000000000002',
 'SYNTHETIC-DOC-2', '1', 1, '["TEST-F01", "TEST-LEGACY", "LOCAL-1"]',
 'TEST-F01', 'TEST-LEGACY', '2025-01-05 09:00+00', 'Current', 'Synthetic test builder',
 'Automated', 'English', 'Restricted');

INSERT INTO nps.clinical_entry (
    entry_uid, patient_uid, nps_block_code, clinical_entry_id, source_facility_id, source_system,
    encounter_uid, date_recorded, clinical_event_date_raw, clinical_event_date_precision,
    original_recorded_description, record_lifecycle_status
)
SELECT ('00000000-0000-4000-8000-' || lpad(f.entry_no::TEXT, 12, '0'))::UUID,
       '00000000-0000-4000-8000-000000000001', f.block_code, 'TEST-ENTRY-' || f.entry_no,
       'TEST-F01', 'TEST-EMR',
       CASE WHEN f.entry_no % 2 = 0 THEN '00000000-0000-4000-8000-000000000011'::UUID
            ELSE '00000000-0000-4000-8000-000000000012'::UUID END,
       '2025-01-04 10:00+00', '2025-01', 'Year-Month', 'Synthetic source statement ' || f.entry_no,
       f.lifecycle
FROM (VALUES (501,'NPS-05','Superseded'), (502,'NPS-05','Corrected'),
    (503,'NPS-05','Active'), (504,'NPS-05','Entered in error'), (601,'NPS-06','Active'),
    (602,'NPS-06','Active'), (701,'NPS-07','Active'), (702,'NPS-07','Active'),
    (801,'NPS-08','Active'), (901,'NPS-09','Corrected'), (902,'NPS-09','Active'),
    (1001,'NPS-10','Active'), (1101,'NPS-11','Active'), (1201,'NPS-12','Active'),
    (1301,'NPS-13','Active'), (1401,'NPS-14','Active'), (1601,'NPS-16','Active'),
    (1701,'NPS-17','Active'), (1801,'NPS-18','Active'), (1901,'NPS-19','Active'),
    (2001,'NPS-20','Active')) f(entry_no, block_code, lifecycle);

UPDATE nps.clinical_entry SET replaces_entry_uid = '00000000-0000-4000-8000-000000000501',
    original_clinical_code = 'TEST-CODE', original_code_system = 'SYNTHETIC-CATALOG'
WHERE entry_uid = '00000000-0000-4000-8000-000000000502';

INSERT INTO nps.problem_diagnosis (entry_uid, patient_uid, problem_diagnosis_code,
    problem_diagnosis_text, problem_status, diagnosis_certainty)
SELECT entry_uid, patient_uid, CASE WHEN clinical_entry_id = 'TEST-ENTRY-503' THEN 'TEST-CODE-ONLY' END,
    CASE WHEN clinical_entry_id <> 'TEST-ENTRY-503' THEN original_recorded_description END,
    CASE WHEN clinical_entry_id = 'TEST-ENTRY-503' THEN 'Resolved' ELSE 'Active' END, 'Suspected'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-05';

INSERT INTO nps.allergy_intolerance (entry_uid, patient_uid, allergen_text,
    allergy_status, verification_status, reaction_text)
SELECT entry_uid, patient_uid, 'Synthetic allergen ' || clinical_entry_id,
    'Unknown', 'Unconfirmed', 'Synthetic documented rash'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-06';

INSERT INTO nps.medication_summary (entry_uid, patient_uid, medicine_name, medication_status, evidence_of_use)
SELECT entry_uid, patient_uid, 'Synthetic medicine ' || clinical_entry_id,
    CASE WHEN clinical_entry_id = 'TEST-ENTRY-701' THEN 'Unknown' ELSE 'Completed' END, 'Prescribed'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-07';

INSERT INTO nps.immunization (entry_uid, patient_uid, vaccine_text, administration_status,
    date_administered_raw, date_administered_unknown_reason)
SELECT entry_uid, patient_uid, 'Synthetic vaccine', 'Unknown', 'Unknown', 'Synthetic source omitted date'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-08';

INSERT INTO nps.diagnostic_report (entry_uid, patient_uid, report_id, report_type,
    test_or_study_text, report_status, imaging_conclusion)
SELECT entry_uid, patient_uid, 'SYNTHETIC-REPORT-' || clinical_entry_id,
    CASE WHEN clinical_entry_id = 'TEST-ENTRY-901' THEN 'Laboratory' ELSE 'Imaging' END,
    'Synthetic diagnostic study',
    CASE WHEN clinical_entry_id = 'TEST-ENTRY-901' THEN 'Corrected' ELSE 'Final' END,
    CASE WHEN clinical_entry_id = 'TEST-ENTRY-902' THEN 'Synthetic imaging impression' END
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-09';

INSERT INTO nps.diagnostic_result_item (report_entry_uid, patient_uid, source_item_id, result_item_text,
    result_value_numeric, result_unit, numeric_result_is_dimensional)
VALUES ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000001',
        'TEST-ITEM-1', 'Synthetic analyte', 13.25, 'g/dL', TRUE);
INSERT INTO nps.diagnostic_result_item (report_entry_uid, patient_uid, source_item_id, result_item_text,
    result_unavailable_reason, interpretation)
VALUES ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000001',
        'TEST-ITEM-2', 'Synthetic pending test', 'Pending', NULL),
       ('00000000-0000-4000-8000-000000000901', '00000000-0000-4000-8000-000000000001',
        'TEST-ITEM-3', 'Synthetic withheld result', 'Withheld', 'SYNTHETIC-WITHHELD-INTERPRETATION');

INSERT INTO nps.procedure_history (entry_uid, patient_uid, procedure_text, procedure_status, procedure_date_raw)
SELECT entry_uid, patient_uid, 'Synthetic procedure', 'Completed', '2025-01'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-10';
INSERT INTO nps.medical_device (entry_uid, patient_uid, device_type_text, device_use_status, device_identifier)
SELECT entry_uid, patient_uid, 'Synthetic prosthesis', 'Unknown', 'SYNTHETIC-MODEL'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-11';
INSERT INTO nps.clinical_alert (entry_uid, patient_uid, alert_description, alert_category, alert_status,
    alert_source, linked_entry_uid)
SELECT entry_uid, patient_uid, 'Synthetic safety alert', 'Safety', 'Active', 'TEST-EMR',
       '00000000-0000-4000-8000-000000000601'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-12';
INSERT INTO nps.advance_directive (entry_uid, patient_uid, directive_preference, directive_status, evidence_source)
SELECT entry_uid, patient_uid, 'SYNTHETIC-WITHHELD-DIRECTIVE', 'Unknown', 'Patient statement'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-13';
INSERT INTO nps.functional_status (entry_uid, patient_uid, function_assessed, finding_text, assessment_date_raw,
    assessment_date_unknown_reason)
SELECT entry_uid, patient_uid, 'Mobility', 'Synthetic assessment', 'Unknown', 'Synthetic date absent'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-14';
INSERT INTO nps.social_history (entry_uid, patient_uid, social_history_topic, reported_response, information_source)
SELECT entry_uid, patient_uid, 'Tobacco', 'Unknown', 'Patient'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-16';
INSERT INTO nps.care_plan (entry_uid, patient_uid, care_plan_id, care_plan_summary, plan_status)
SELECT entry_uid, patient_uid, 'SYNTHETIC-PLAN-1', 'Synthetic instructions', 'Active'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-17';
INSERT INTO nps.care_plan_action (care_plan_entry_uid, patient_uid, source_action_id,
    planned_action_category, planned_action_text, action_status, receiving_facility_id)
VALUES ('00000000-0000-4000-8000-000000001701', '00000000-0000-4000-8000-000000000001',
    'TEST-ACTION-1', 'Referral', 'Synthetic referral', 'Pending', 'TEST-F02'),
       ('00000000-0000-4000-8000-000000001701', '00000000-0000-4000-8000-000000000001',
    'TEST-ACTION-2', 'Review', 'Synthetic review', NULL, NULL);
INSERT INTO nps.past_problem (entry_uid, patient_uid, past_condition_text, historical_status, referenced_problem_entry_uid)
SELECT entry_uid, patient_uid, 'Synthetic past condition', 'Resolved', '00000000-0000-4000-8000-000000000503'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-18';
INSERT INTO nps.patient_story (entry_uid, patient_uid, patient_narrative, information_source, date_recorded_raw,
    date_recorded_unknown_reason, language_used)
SELECT entry_uid, patient_uid, 'SYNTHETIC-RESTRICTED-STORY', 'Patient', 'Unknown', 'Synthetic date absent', 'Krio'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-19';
INSERT INTO nps.vital_sign (entry_uid, patient_uid, vital_sign, value_raw, bp_systolic, bp_diastolic,
    unit, measurement_date_raw, measurement_date_time)
SELECT entry_uid, patient_uid, 'BP', '120/80', 120, 80, 'mmHg', '2025-01-04T09:00Z', '2025-01-04 09:00+00'
FROM nps.clinical_entry WHERE nps_block_code = 'NPS-20';

INSERT INTO nps.section_completeness (document_uid, patient_uid, nps_block_code, nps_block_name,
    section_information_status, extraction_status, section_access_restriction)
SELECT d.document_uid, d.patient_uid, b.block_code, b.block_name,
    CASE WHEN b.block_code = 'NPS-15' THEN 'Unknown' ELSE 'Entries present' END,
    CASE WHEN b.block_code = 'NPS-15' THEN 'Unsupported' ELSE 'Complete' END,
    CASE b.block_code WHEN 'NPS-13' THEN 'Withheld' WHEN 'NPS-19' THEN 'Restricted' ELSE 'Normal' END
FROM nps.summary_document d CROSS JOIN nps.block_catalog b
WHERE d.document_id = 'SYNTHETIC-DOC-1' AND b.is_clinical_section;

INSERT INTO nps.section_completeness (document_uid, patient_uid, nps_block_code, nps_block_name,
    section_information_status, extraction_status, section_access_restriction, absence_evidence_ref)
SELECT d.document_uid, d.patient_uid, b.block_code, b.block_name,
    'None known', 'Complete', 'Normal', 'SYNTHETIC-CLINICAL-ASSESSMENT-1'
FROM nps.summary_document d CROSS JOIN nps.block_catalog b
WHERE d.document_id = 'SYNTHETIC-DOC-2' AND b.block_code = 'NPS-06';

RESET ROLE;
SET LOCAL ROLE nps_publisher;
SELECT nps.publish_patient_summary('00000000-0000-4000-8000-000000000021', revision, TRUE)
FROM nps.patient_revision WHERE patient_uid = '00000000-0000-4000-8000-000000000001';
SELECT nps.publish_patient_summary('00000000-0000-4000-8000-000000000022', revision, FALSE)
FROM nps.patient_revision WHERE patient_uid = '00000000-0000-4000-8000-000000000002';
COMMIT;
