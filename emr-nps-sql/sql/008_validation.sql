-- Restricted data-quality views. Return keys and rule codes instead of clinical text.
BEGIN;

CREATE TABLE nps.code_binding (
    source_facility_id VARCHAR(128) NOT NULL,
    source_system VARCHAR(150) NOT NULL,
    element_id VARCHAR(16) NOT NULL REFERENCES nps.data_dictionary_element,
    code_system TEXT NOT NULL DEFAULT '',
    catalog_version TEXT NOT NULL,
    PRIMARY KEY (source_facility_id, source_system, element_id, code_system)
);

CREATE TABLE nps.allowed_code (
    source_facility_id VARCHAR(128) NOT NULL,
    source_system VARCHAR(150) NOT NULL,
    element_id VARCHAR(16) NOT NULL,
    code_system TEXT NOT NULL DEFAULT '',
    code_value TEXT NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (source_facility_id, source_system, element_id, code_system, code_value),
    FOREIGN KEY (source_facility_id, source_system, element_id, code_system)
        REFERENCES nps.code_binding
);

-- Missing typed children are possible during staging. The FK checks the reverse
-- direction as well as patient ownership and block consistency on insert.
CREATE VIEW nps.clinical_detail_presence AS
    SELECT entry_uid FROM nps.problem_diagnosis UNION ALL
    SELECT entry_uid FROM nps.allergy_intolerance UNION ALL
    SELECT entry_uid FROM nps.medication_summary UNION ALL
    SELECT entry_uid FROM nps.immunization UNION ALL
    SELECT entry_uid FROM nps.diagnostic_report UNION ALL
    SELECT entry_uid FROM nps.procedure_history UNION ALL
    SELECT entry_uid FROM nps.medical_device UNION ALL
    SELECT entry_uid FROM nps.clinical_alert UNION ALL
    SELECT entry_uid FROM nps.advance_directive UNION ALL
    SELECT entry_uid FROM nps.functional_status UNION ALL
    SELECT entry_uid FROM nps.social_history UNION ALL
    SELECT entry_uid FROM nps.care_plan UNION ALL
    SELECT entry_uid FROM nps.past_problem UNION ALL
    SELECT entry_uid FROM nps.patient_story UNION ALL
    SELECT entry_uid FROM nps.vital_sign;

CREATE VIEW nps.clinical_code_use AS
SELECT c.entry_uid, c.patient_uid, c.source_facility_id, c.source_system,
       v.element_id, v.code_system, v.code_value
FROM nps.clinical_entry c
LEFT JOIN nps.problem_diagnosis pd USING (entry_uid)
LEFT JOIN nps.allergy_intolerance ai USING (entry_uid)
LEFT JOIN nps.medication_summary ms USING (entry_uid)
LEFT JOIN nps.immunization im USING (entry_uid)
LEFT JOIN nps.diagnostic_report dr USING (entry_uid)
LEFT JOIN nps.procedure_history ph USING (entry_uid)
LEFT JOIN nps.medical_device md USING (entry_uid)
LEFT JOIN nps.past_problem pp USING (entry_uid)
CROSS JOIN LATERAL (VALUES
    ('NPS-04-10', COALESCE(c.original_code_system, ''), c.original_clinical_code),
    ('NPS-05-01', '', pd.problem_diagnosis_code),
    ('NPS-06-01', '', ai.allergen_code),
    ('NPS-06-05', '', ai.reaction_code),
    ('NPS-07-01', '', ms.medicine_code),
    ('NPS-07-10', '', ms.reason_for_use_code),
    ('NPS-08-01', '', im.vaccine_code),
    ('NPS-09-03', '', dr.test_or_study_code),
    ('NPS-10-01', '', ph.procedure_code),
    ('NPS-11-01', '', md.device_type_code),
    ('NPS-18-01', '', pp.past_condition_code)
) v(element_id, code_system, code_value)
WHERE v.code_value IS NOT NULL
UNION ALL
SELECT ri.result_item_uid, c.patient_uid, c.source_facility_id, c.source_system,
       'NPS-09-05', '', ri.result_item_code
FROM nps.diagnostic_result_item ri JOIN nps.clinical_entry c ON c.entry_uid = ri.report_entry_uid
WHERE ri.result_item_code IS NOT NULL;

CREATE VIEW nps.validation_issues AS
WITH active_entries AS (
    SELECT c.* FROM nps.clinical_entry c
    WHERE c.record_lifecycle_status IN ('Active', 'Corrected')
), issuer_keys AS (
    SELECT patient_uid, primary_source_facility_id AS facility, primary_source_system AS issuer,
           primary_source_patient_id AS identifier
    FROM nps.patient
    UNION
    SELECT patient_uid, issuing_facility_id, issuing_system, identifier_value
    FROM nps.patient_identifier WHERE identifier_status = 'Active' AND nps_element_id = 'NPS-02-02'
), duplicate_keys AS (
    SELECT facility, issuer, identifier FROM issuer_keys
    GROUP BY facility, issuer, identifier HAVING count(*) > 1
), clinical_counts AS (
    SELECT patient_uid, nps_block_code, count(*) AS entries
    FROM active_entries JOIN nps.clinical_detail_presence USING (entry_uid)
    GROUP BY patient_uid, nps_block_code
)
SELECT 'ERROR'::TEXT AS severity, 'MISSING_SOURCE_IDENTIFIER'::TEXT AS issue_code,
       'NPS-02-02'::TEXT AS dictionary_ref, p.patient_uid, p.patient_uid AS record_uid
FROM nps.patient p
WHERE NULLIF(btrim(p.primary_source_patient_id), '') IS NULL
   OR NULLIF(btrim(p.primary_source_facility_id), '') IS NULL
   OR NULLIF(btrim(p.primary_source_system), '') IS NULL
UNION ALL
SELECT 'ERROR', 'AMBIGUOUS_SOURCE_IDENTIFIER', 'NPS-02-02', i.patient_uid, i.patient_uid
FROM issuer_keys i JOIN duplicate_keys USING (facility, issuer, identifier)
UNION ALL
SELECT 'ERROR', 'DUPLICATE_CLINICAL_SOURCE_KEY', 'NPS-04-01', c.patient_uid, c.entry_uid
FROM nps.clinical_entry c
WHERE EXISTS (
    SELECT 1 FROM nps.clinical_entry other
    WHERE (other.source_facility_id, other.source_system, other.nps_block_code, other.clinical_entry_id)
        = (c.source_facility_id, c.source_system, c.nps_block_code, c.clinical_entry_id)
      AND other.entry_uid <> c.entry_uid
)
UNION ALL
SELECT 'ERROR', 'MISSING_FACILITY_PROVENANCE', 'NPS-04-02', c.patient_uid, c.entry_uid
FROM nps.clinical_entry c WHERE NULLIF(btrim(c.source_facility_id), '') IS NULL
UNION ALL
SELECT 'ERROR', 'ORPHANED_CLINICAL_ENTRY', 'NPS-04-01', c.patient_uid, c.entry_uid
FROM nps.clinical_entry c LEFT JOIN nps.patient p USING (patient_uid)
WHERE p.patient_uid IS NULL
UNION ALL
SELECT 'ERROR', 'MISSING_TYPED_CLINICAL_ENTRY', c.nps_block_code, c.patient_uid, c.entry_uid
FROM active_entries c LEFT JOIN nps.clinical_detail_presence t USING (entry_uid)
WHERE t.entry_uid IS NULL
UNION ALL
SELECT 'ERROR', 'CORRECTION_PREDECESSOR_STILL_VISIBLE', 'NPS-04-01', c.patient_uid, c.entry_uid
FROM active_entries c JOIN active_entries prior ON prior.entry_uid = c.replaces_entry_uid
UNION ALL
SELECT 'ERROR', 'BIRTH_DATE_INCONSISTENT', 'NPS-02-05', patient_uid, patient_uid
FROM nps.patient
WHERE date_of_birth_exact > CURRENT_DATE
   OR (date_of_birth_raw ~ '^\d{4}-\d{2}-\d{2}$' AND NOT pg_input_is_valid(date_of_birth_raw, 'date'))
   OR (date_of_birth_precision IN ('Year', 'Year-Month') AND date_of_birth_exact IS NOT NULL)
UNION ALL
SELECT 'ERROR', 'AGE_ASSESSMENT_INCONSISTENT', 'NPS-02-06', patient_uid, patient_uid
FROM nps.patient
WHERE date_of_age_assessment > CURRENT_DATE
   OR (date_of_birth_exact IS NOT NULL AND date_of_age_assessment < date_of_birth_exact)
UNION ALL
SELECT 'ERROR', 'CLINICAL_DATE_INVALID', 'NPS-04-05', patient_uid, entry_uid
FROM nps.clinical_entry
WHERE clinical_event_date_raw ~ '^\d{4}-\d{2}-\d{2}$'
  AND NOT pg_input_is_valid(clinical_event_date_raw, 'date')
UNION ALL
SELECT 'ERROR', 'DOCUMENT_RECEIVED_BEFORE_GENERATED', 'NPS-01-16', patient_uid, document_uid
FROM nps.summary_document WHERE received_date_time < generated_date_time
UNION ALL
SELECT 'WARN', 'REPORT_WITHOUT_OBSERVATIONS', 'NPS-09-05', r.patient_uid, r.entry_uid
FROM nps.diagnostic_report r JOIN active_entries c USING (entry_uid)
WHERE r.report_status <> 'Cancelled' AND r.imaging_conclusion IS NULL
  AND NOT EXISTS (SELECT 1 FROM nps.diagnostic_result_item i WHERE i.report_entry_uid = r.entry_uid)
UNION ALL
SELECT 'WARN', 'NUMERIC_RESULT_UNIT_NEEDS_REVIEW', 'NPS-09-07', patient_uid, result_item_uid
FROM nps.diagnostic_result_item
WHERE result_value_numeric IS NOT NULL AND NULLIF(btrim(result_unit), '') IS NULL
  AND numeric_result_is_dimensional IS DISTINCT FROM FALSE
UNION ALL
SELECT CASE WHEN b.element_id IS NULL THEN 'INFO' ELSE 'WARN' END,
       CASE WHEN b.element_id IS NULL THEN 'CODE_UNVERIFIED' ELSE 'CODE_UNSUPPORTED' END,
       u.element_id, u.patient_uid, u.entry_uid
FROM nps.clinical_code_use u
LEFT JOIN nps.code_binding b USING (source_facility_id, source_system, element_id, code_system)
WHERE b.element_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM nps.allowed_code allowed
    WHERE (allowed.source_facility_id, allowed.source_system, allowed.element_id, allowed.code_system, allowed.code_value)
        = (u.source_facility_id, u.source_system, u.element_id, u.code_system, u.code_value)
      AND allowed.active
)
UNION ALL
SELECT 'ERROR', 'REQUIRED_SECTION_ASSESSMENT_MISSING', bc.block_code, d.patient_uid, d.document_uid
FROM nps.summary_document d CROSS JOIN nps.block_catalog bc
WHERE d.document_status = 'Current' AND bc.is_clinical_section
  AND NOT EXISTS (SELECT 1 FROM nps.section_completeness sc
      WHERE sc.document_uid = d.document_uid AND sc.nps_block_code = bc.block_code)
UNION ALL
SELECT 'WARN', 'SECTION_ASSESSMENT_ENTRY_MISMATCH', s.nps_block_code, s.patient_uid, s.document_uid
FROM nps.section_completeness s JOIN nps.summary_document d USING (document_uid)
LEFT JOIN clinical_counts c ON c.patient_uid = s.patient_uid AND c.nps_block_code = s.nps_block_code
WHERE d.document_status = 'Current'
  AND ((s.section_information_status = 'Entries present' AND COALESCE(c.entries, 0) = 0)
       OR (s.section_information_status = 'None known' AND COALESCE(c.entries, 0) > 0))
UNION ALL
SELECT 'WARN', 'ACTIVE_PROBLEM_LINKED_AS_PAST', 'NPS-18-02', h.patient_uid, h.entry_uid
FROM nps.past_problem h JOIN nps.problem_diagnosis p ON p.entry_uid = h.referenced_problem_entry_uid
JOIN active_entries c ON c.entry_uid = p.entry_uid
WHERE p.problem_status = 'Active'
UNION ALL
SELECT 'WARN', 'NO_FRESH_RELEASE', 'NPS-01', p.patient_uid, p.patient_uid
FROM nps.patient p JOIN nps.patient_revision v USING (patient_uid)
WHERE p.record_status = 'Active' AND NOT EXISTS (
    SELECT 1 FROM nps.summary_document d JOIN nps.summary_release r USING (document_uid)
    WHERE d.patient_uid = p.patient_uid AND d.document_status = 'Current' AND r.patient_revision = v.revision
      AND (d.source_facility_id, d.source_emr) = (p.primary_source_facility_id, p.primary_source_system)
)
UNION ALL
SELECT 'ERROR', 'CHECKPOINT_PASSED_UNACKNOWLEDGED_EVENT', 'SYNC', o.patient_uid, o.event_id
FROM nps.sync_outbox_event o JOIN nps.sync_checkpoint c USING (source_facility_id)
WHERE o.change_seq <= c.last_acknowledged_change_seq AND o.transfer_status NOT IN ('Acknowledged', 'Cancelled')
UNION ALL
SELECT 'ERROR', 'CHECKPOINT_TARGET_MISSING', 'SYNC', NULL::UUID, NULL::UUID
FROM nps.sync_checkpoint c WHERE c.last_acknowledged_change_seq > 0
  AND NOT EXISTS (
      SELECT 1 FROM nps.sync_outbox_event o WHERE o.source_facility_id = c.source_facility_id
        AND o.change_seq = c.last_acknowledged_change_seq AND o.transfer_status = 'Acknowledged'
  )
UNION ALL
SELECT 'WARN', 'TRANSFER_FAILED_OR_LEASE_EXPIRED', 'SYNC', o.patient_uid, o.event_id
FROM nps.sync_outbox_event o
WHERE o.transfer_status IN ('Retry', 'Failed') OR
      (o.transfer_status = 'In_Flight' AND o.lease_until <= clock_timestamp())
UNION ALL
SELECT 'WARN', 'INCOMING_CONFLICT_OPEN', 'SYNC', NULL::UUID, c.event_id
FROM nps.sync_conflict_log c WHERE c.resolved_at IS NULL;

COMMENT ON VIEW nps.validation_issues IS
    'Scoped quality findings. Identity keys are still sensitive. Code checks use only configured approved catalogues.';

COMMIT;
