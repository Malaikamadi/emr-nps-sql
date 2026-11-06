-- Assemble the local NPS JSON profile from an authorised release candidate.
BEGIN;

-- =============================================================================
-- HELPER: CHECK WHETHER A SECTION'S ENTRIES MAY BE EMITTED
-- =============================================================================
CREATE OR REPLACE FUNCTION nps.is_section_visible(
    p_access_restriction VARCHAR,
    p_include_restricted BOOLEAN
)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_access_restriction IS NULL OR p_access_restriction = 'Withheld' THEN FALSE
        WHEN p_access_restriction = 'Restricted' AND NOT COALESCE(p_include_restricted, FALSE) THEN FALSE
        ELSE TRUE
    END;
$$;

-- =============================================================================
-- NPS-04-01 through NPS-04-10, shared by every typed clinical block.
CREATE FUNCTION nps.clinical_metadata(p_entry nps.clinical_entry)
RETURNS JSONB
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object(
        'nps0401ClinicalEntryId', p_entry.clinical_entry_id,
        'nps0402SourceFacility', p_entry.source_facility_id,
        'nps0403SourceSystem', p_entry.source_system,
        'nps0404DateRecorded', p_entry.date_recorded,
        'nps0405ClinicalEventDateRaw', p_entry.clinical_event_date_raw,
        'nps0405ClinicalEventTimestamp', p_entry.clinical_event_timestamp,
        'nps0405ClinicalEventDatePrecision', p_entry.clinical_event_date_precision,
        'nps0406OriginalRecordedDescription', p_entry.original_recorded_description,
        'nps0407SourceProvider', p_entry.source_provider_id,
        'nps0408SourceEncounter', COALESCE(p_entry.source_encounter_id, (
            SELECT e.source_encounter_id
            FROM nps.clinical_encounter e
            WHERE e.encounter_uid = p_entry.encounter_uid AND e.record_status <> 'Entered in error'
        )),
        'nps0409Verification', p_entry.verification,
        'nps0410OriginalClinicalCode', p_entry.original_clinical_code,
        'nps0410OriginalCodeSystem', p_entry.original_code_system,
        'recordLifecycleStatus', p_entry.record_lifecycle_status,
        'updatedAt', p_entry.updated_at
    );
$$;

-- Private assembler for a current, explicitly selected document.
CREATE OR REPLACE FUNCTION nps.assemble_patient_summary(
    p_patient_id         UUID,
    p_include_restricted BOOLEAN,
    p_document_uid UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
SET TimeZone = 'UTC'
AS $$
DECLARE
    v_resolved_patient_uid UUID;
    v_patient_row          nps.patient%ROWTYPE;
    v_doc_row              nps.summary_document%ROWTYPE;
    v_summary_json         JSONB;
BEGIN
    SELECT * INTO v_patient_row FROM nps.patient
    WHERE patient_uid = p_patient_id AND record_status = 'Active';
    IF NOT FOUND THEN RETURN NULL; END IF;
    v_resolved_patient_uid := v_patient_row.patient_uid;

    SELECT * INTO v_doc_row FROM nps.summary_document
    WHERE document_uid = p_document_uid AND patient_uid = p_patient_id
      AND document_status = 'Current';
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF v_doc_row.confidentiality <> 'Normal' AND NOT COALESCE(p_include_restricted, FALSE) THEN
        RETURN NULL;
    END IF;

    WITH assessments AS (
        SELECT bc.block_code, bc.block_name, bc.priority_level,
               sc.section_information_status, sc.extraction_status, sc.last_assessed_date,
               sc.reason_information_unavailable, sc.reason_unavailable_other,
               sc.section_access_restriction, sc.section_completeness_uid,
               sc.section_completeness_uid IS NOT NULL
                   AND nps.is_section_visible(sc.section_access_restriction, p_include_restricted)
                   AND sc.section_information_status <> 'Withheld' AS may_disclose
        FROM nps.block_catalog bc
        LEFT JOIN nps.section_completeness sc
          ON sc.document_uid = v_doc_row.document_uid AND sc.nps_block_code = bc.block_code
        WHERE bc.is_clinical_section
    ), sec_status AS (
        SELECT block_code, block_name, priority_level,
               CASE WHEN section_completeness_uid IS NULL THEN 'Unknown'
                    WHEN NOT may_disclose THEN 'Withheld'
                    ELSE section_information_status END AS info_status,
               CASE WHEN may_disclose THEN extraction_status END AS extraction_status,
               CASE WHEN may_disclose THEN last_assessed_date END AS last_assessed_date,
               CASE WHEN section_completeness_uid IS NULL THEN 'Not recorded'
                    WHEN NOT may_disclose THEN 'Restricted'
                    ELSE reason_information_unavailable END AS reason_unavailable,
               CASE WHEN may_disclose THEN reason_unavailable_other END AS reason_unavailable_other,
               section_access_restriction AS access_restriction,
               may_disclose AND section_information_status = 'Entries present'
                 AND extraction_status IN ('Complete', 'Partial') AS is_visible
        FROM assessments
    ),
    -- Block 05: Problems & diagnoses
    sec_05_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps0501ProblemDiagnosisCode', pd.problem_diagnosis_code,
                           'nps0501ProblemDiagnosisText', pd.problem_diagnosis_text,
                           'nps0502ProblemStatus',        pd.problem_status,
                           'nps0503DiagnosisCertainty',   pd.diagnosis_certainty,
                           'nps0504OnsetDateRaw',         pd.onset_date_raw,
                           'nps0504OnsetDateExact',       pd.onset_date_exact,
                           'nps0505ResolutionDateRaw',    pd.resolution_date_raw,
                           'nps0505ResolutionDateExact',  pd.resolution_date_exact,
                           'nps0506Severity',             pd.severity,
                           'nps0506SeverityOther',        pd.severity_other,
                           'nps0507DiagnosisBasis',       pd.diagnosis_basis,
                           'nps0508ManagementNote',       pd.management_note
                       )
                       ORDER BY CASE pd.problem_status WHEN 'Active' THEN 1 ELSE 2 END,
                                pd.onset_date_exact DESC NULLS LAST,
                                ce.clinical_entry_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.problem_diagnosis pd
          JOIN nps.clinical_entry ce ON ce.entry_uid = pd.entry_uid
         WHERE pd.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-05' AND s.is_visible)
    ),
    -- Block 06: Allergies & intolerances
    sec_06_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps0601AllergenCode',       ai.allergen_code,
                           'nps0601AllergenText',       ai.allergen_text,
                           'nps0602AllergyStatus',      ai.allergy_status,
                           'nps0603VerificationStatus', ai.verification_status,
                           'nps0604AllergyCategory',    ai.allergy_category,
                           'nps0605ReactionCode',       ai.reaction_code,
                           'nps0605ReactionText',       ai.reaction_text,
                           'nps0606ReactionSeverity',   ai.reaction_severity,
                           'nps0607Criticality',        ai.criticality,
                           'nps0608FirstNotedDateRaw',  ai.first_noted_date_raw,
                           'nps0608FirstNotedDate',     ai.first_noted_date
                       )
                       ORDER BY CASE ai.allergy_status WHEN 'Active' THEN 1 ELSE 2 END,
                                ai.first_noted_date DESC NULLS LAST,
                                ce.clinical_entry_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.allergy_intolerance ai
          JOIN nps.clinical_entry ce ON ce.entry_uid = ai.entry_uid
         WHERE ai.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-06' AND s.is_visible)
    ),
    -- Block 07: Medication summary
    sec_07_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps0701MedicineCode',     ms.medicine_code,
                           'nps0701MedicineName',     ms.medicine_name,
                           'nps0702MedicationStatus', ms.medication_status,
                           'nps0703EvidenceOfUse',    ms.evidence_of_use,
                           'nps0704Strength',         ms.strength,
                           'nps0705DoseValue',        ms.dose_value,
                           'nps0705DoseUnit',         ms.dose_unit,
                           'nps0705DoseText',         ms.dose_text,
                           'nps0706Route',            ms.route,
                           'nps0706RouteOther',       ms.route_other,
                           'nps0707Frequency',        ms.frequency,
                           'nps0708StartDateRaw',     ms.start_date_raw,
                           'nps0708StartDate',        ms.start_date,
                           'nps0709EndDateRaw',       ms.end_date_raw,
                           'nps0709EndDate',          ms.end_date,
                           'nps0710ReasonForUseCode', ms.reason_for_use_code,
                           'nps0710ReasonForUseText', ms.reason_for_use_text,
                           'nps0711PrescriberId',     ms.prescriber_id
                       )
                       ORDER BY CASE ms.medication_status WHEN 'Active' THEN 1 ELSE 2 END,
                                ms.start_date DESC NULLS LAST,
                                ce.clinical_entry_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.medication_summary ms
          JOIN nps.clinical_entry ce ON ce.entry_uid = ms.entry_uid
         WHERE ms.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-07' AND s.is_visible)
    ),
    -- Block 08: Immunizations
    sec_08_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps0801VaccineCode',                   im.vaccine_code,
                           'nps0801VaccineText',                   im.vaccine_text,
                           'nps0802AdministrationStatus',          im.administration_status,
                           'nps0803DateAdministeredRaw',           im.date_administered_raw,
                           'nps0803DateAdministeredExact',         im.date_administered_exact,
                           'nps0803DateAdministeredUnknownReason', im.date_administered_unknown_reason,
                           'nps0804DoseNumber',                    im.dose_number,
                           'nps0805VaccineBatch',                  im.vaccine_batch,
                           'nps0806EvidenceSource',                im.evidence_source,
                           'nps0806EvidenceSourceOther',           im.evidence_source_other,
                           'nps0807AdministeringFacilityId',       im.administering_facility_id,
                           'nps0808NextDoseDueDate',               im.next_dose_due_date
                       )
                       ORDER BY im.date_administered_exact DESC NULLS LAST,
                                ce.clinical_entry_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.immunization im
          JOIN nps.clinical_entry ce ON ce.entry_uid = im.entry_uid
         WHERE im.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-08' AND s.is_visible)
    ),
    -- Block 09: Laboratory & imaging results (1..* items nested inside each report)
    sec_09_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps0901ReportId',          dr.report_id,
                           'nps0902ReportType',        dr.report_type,
                           'nps0903TestOrStudyCode',   dr.test_or_study_code,
                           'nps0903TestOrStudyText',   dr.test_or_study_text,
                           'nps0904ReportStatus',      dr.report_status,
                           'nps0908ResultDateTime',    dr.result_date_time,
                           'nps0911ImagingConclusion', dr.imaging_conclusion,
                           'resultObservations', COALESCE(
                               (
                                   SELECT jsonb_agg(
                                              jsonb_build_object(
                                                  'nps0905ResultItemCode',          ri.result_item_code,
                                                  'nps0905ResultItemText',          ri.result_item_text,
                                                  'nps0906ResultValueNumeric',      ri.result_value_numeric,
                                                  'nps0906ResultValueChoice',       ri.result_value_choice,
                                                  'nps0906ResultValueNarrative',    ri.result_value_narrative,
                                                  'nps0907ResultUnit',              CASE WHEN ri.result_unavailable_reason IS DISTINCT FROM 'Withheld' THEN ri.result_unit END,
                                                  'nps0908ResultDateTime',          ri.result_date_time,
                                                  'nps0909ReferenceRange',          CASE WHEN ri.result_unavailable_reason IS DISTINCT FROM 'Withheld' THEN ri.reference_range END,
                                                  'nps0910Interpretation',          CASE WHEN ri.result_unavailable_reason IS DISTINCT FROM 'Withheld' THEN ri.interpretation END,
                                                  'nps0912ResultUnavailableReason', ri.result_unavailable_reason,
                                                  'nps0912ResultUnavailableOther',  CASE WHEN ri.result_unavailable_reason IS DISTINCT FROM 'Withheld' THEN ri.result_unavailable_reason_other END
                                              )
                                              ORDER BY ri.created_at, ri.result_item_text, ri.result_item_uid
                                          )
                                     FROM nps.diagnostic_result_item ri
                                    WHERE ri.report_entry_uid = dr.entry_uid
                               ),
                               '[]'::jsonb
                           )
                       )
                       ORDER BY COALESCE(dr.result_date_time, ce.date_recorded) DESC NULLS LAST,
                                dr.report_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.diagnostic_report dr
          JOIN nps.clinical_entry ce ON ce.entry_uid = dr.entry_uid
         WHERE dr.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND dr.report_status <> 'Cancelled'
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-09' AND s.is_visible)
    ),
    -- Block 10: History of procedures
    sec_10_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1001ProcedureCode',        ph.procedure_code,
                           'nps1001ProcedureText',        ph.procedure_text,
                           'nps1002ProcedureStatus',      ph.procedure_status,
                           'nps1003ProcedureDateRaw',     ph.procedure_date_raw,
                           'nps1003ProcedureDateTime',    ph.procedure_date_time,
                           'nps1004PerformingFacilityId', ph.performing_facility_id,
                           'nps1005Outcome',              ph.outcome,
                           'nps1006Complications',        ph.complications
                       )
                       ORDER BY ph.procedure_date_time DESC NULLS LAST,
                                ce.clinical_entry_id ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.procedure_history ph
          JOIN nps.clinical_entry ce ON ce.entry_uid = ph.entry_uid
         WHERE ph.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-10' AND s.is_visible)
    ),
    -- Block 11: Medical devices
    sec_11_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1101DeviceTypeCode',   md.device_type_code,
                           'nps1101DeviceTypeText',   md.device_type_text,
                           'nps1102DeviceUseStatus',  md.device_use_status,
                           'nps1103DateStartedRaw',   md.date_started_raw,
                           'nps1103DateStarted',      md.date_started,
                           'nps1104DateStoppedRaw',   md.date_stopped_raw,
                           'nps1104DateStopped',      md.date_stopped,
                           'nps1105BodySite',         md.body_site,
                           'nps1106DeviceIdentifier', md.device_identifier
                       )
                       ORDER BY CASE md.device_use_status WHEN 'Active' THEN 1 ELSE 2 END,
                                md.date_started DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.medical_device md
          JOIN nps.clinical_entry ce ON ce.entry_uid = md.entry_uid
         WHERE md.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-11' AND s.is_visible)
    ),
    -- Block 12: Alerts
    sec_12_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1201AlertDescription',      ca.alert_description,
                           'nps1202AlertCategory',         ca.alert_category,
                           'nps1203AlertStatus',           ca.alert_status,
                           'nps1204AlertSource',           ca.alert_source,
                           'nps1205EffectiveDateRaw',      ca.effective_date_raw,
                           'nps1205EffectiveDate',         ca.effective_date,
                           'nps1206LinkedClinicalEntryId', (
                               SELECT target.clinical_entry_id
                               FROM nps.clinical_entry target
                               JOIN sec_status st ON st.block_code = target.nps_block_code AND st.is_visible
                               WHERE target.entry_uid = ca.linked_entry_uid
                                 AND target.record_lifecycle_status IN ('Active', 'Corrected')
                           )
                       )
                       ORDER BY ca.effective_date DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.clinical_alert ca
          JOIN nps.clinical_entry ce ON ce.entry_uid = ca.entry_uid
         WHERE ca.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-12' AND s.is_visible)
    ),
    -- Block 13: Advance directives
    sec_13_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1301DirectivePreference', ad.directive_preference,
                           'nps1302DirectiveStatus',     ad.directive_status,
                           'nps1303EvidenceSource',      ad.evidence_source,
                           'nps1303EvidenceSourceOther', ad.evidence_source_other,
                           'nps1304DateRecordedRaw',     ad.date_recorded_raw,
                           'nps1304DateRecorded',        ad.date_recorded
                       )
                       ORDER BY ad.date_recorded DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.advance_directive ad
          JOIN nps.clinical_entry ce ON ce.entry_uid = ad.entry_uid
         WHERE ad.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-13' AND s.is_visible)
    ),
    -- Block 14: Functional status
    sec_14_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1401FunctionAssessed',            fs.function_assessed,
                           'nps1401FunctionAssessedOther',       fs.function_assessed_other,
                           'nps1402FindingText',                 fs.finding_text,
                           'nps1402FindingScore',                fs.finding_score,
                           'nps1403AssessmentDateRaw',           fs.assessment_date_raw,
                           'nps1403AssessmentDate',              fs.assessment_date,
                           'nps1403AssessmentDateUnknownReason', fs.assessment_date_unknown_reason,
                           'nps1404AssistanceNeeded',            fs.assistance_needed
                       )
                       ORDER BY fs.assessment_date DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.functional_status fs
          JOIN nps.clinical_entry ce ON ce.entry_uid = fs.entry_uid
         WHERE fs.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-14' AND s.is_visible)
    ),
    -- Block 16: Social history
    sec_16_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1601SocialHistoryTopic',     sh.social_history_topic,
                           'nps1601TopicOther',             sh.topic_other,
                           'nps1602ReportedResponse',       sh.reported_response,
                           'nps1603InformationSource',      sh.information_source,
                           'nps1603InformationSourceOther', sh.information_source_other,
                           'nps1604ObservationDateRaw',     sh.observation_date_raw,
                           'nps1604ObservationDate',        sh.observation_date,
                           'nps1605FrequencyQuantity',      sh.frequency_quantity
                       )
                       ORDER BY sh.observation_date DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.social_history sh
          JOIN nps.clinical_entry ce ON ce.entry_uid = sh.entry_uid
         WHERE sh.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-16' AND s.is_visible)
    ),
    -- Block 17: Care plan & follow-up
    sec_17_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1701CarePlanId',      cp.care_plan_id,
                           'nps1702CarePlanSummary', cp.care_plan_summary,
                           'nps1703PlanStatus',      cp.plan_status,
                           'plannedActions', COALESCE(
                               (
                                   SELECT jsonb_agg(
                                              jsonb_build_object(
                                                  'nps1704PlannedActionCategory', cpa.planned_action_category,
                                                  'nps1704PlannedActionText',     cpa.planned_action_text,
                                                  'nps1705ActionStatus',          cpa.action_status,
                                                  'nps1706DueDateRaw',            cpa.due_date_raw,
                                                  'nps1706DueDate',               cpa.due_date,
                                                  'nps1707ReceivingFacilityId',   cpa.receiving_facility_id
                                              )
                                              ORDER BY cpa.due_date ASC NULLS LAST
                                          )
                                     FROM nps.care_plan_action cpa
                                    WHERE cpa.care_plan_entry_uid = cp.entry_uid
                               ),
                               '[]'::jsonb
                           )
                       )
                       ORDER BY CASE cp.plan_status WHEN 'Active' THEN 1 ELSE 2 END,
                                ce.date_recorded DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.care_plan cp
          JOIN nps.clinical_entry ce ON ce.entry_uid = cp.entry_uid
         WHERE cp.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-17' AND s.is_visible)
    ),
    -- Block 18: Past problems
    sec_18_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1801PastConditionCode',         pp.past_condition_code,
                           'nps1801PastConditionText',         pp.past_condition_text,
                           'nps1801ReferencedProblemSourceId', (
                               SELECT target.clinical_entry_id
                               FROM nps.clinical_entry target
                               JOIN sec_status st ON st.block_code = target.nps_block_code AND st.is_visible
                               WHERE target.entry_uid = pp.referenced_problem_entry_uid
                                 AND target.record_lifecycle_status IN ('Active', 'Corrected')
                           ),
                           'nps1802HistoricalStatus',          pp.historical_status,
                           'nps1803OnsetDateRaw',              pp.onset_date_raw,
                           'nps1803OnsetDate',                 pp.onset_date,
                           'nps1803ResolutionDateRaw',         pp.resolution_date_raw,
                           'nps1803ResolutionDate',            pp.resolution_date,
                           'nps1804LastingEffects',            pp.lasting_effects
                       )
                       ORDER BY pp.resolution_date DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.past_problem pp
          JOIN nps.clinical_entry ce ON ce.entry_uid = pp.entry_uid
         WHERE pp.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-18' AND s.is_visible)
    ),
    -- Block 19: Patient story
    sec_19_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps1901PatientNarrative',          ps.patient_narrative,
                           'nps1902InformationSource',         ps.information_source,
                           'nps1902InformationSourceOther',    ps.information_source_other,
                           'nps1903DateRecordedRaw',           ps.date_recorded_raw,
                           'nps1903DateRecordedTime',          ps.date_recorded_time,
                           'nps1903DateRecordedUnknownReason', ps.date_recorded_unknown_reason,
                           'nps1904LanguageUsed',              ps.language_used,
                           'nps1904LanguageOther',             ps.language_other,
                           'nps1905PatientPriorities',         ps.patient_priorities
                       )
                       ORDER BY ps.date_recorded_time DESC NULLS LAST, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.patient_story ps
          JOIN nps.clinical_entry ce ON ce.entry_uid = ps.entry_uid
         WHERE ps.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-19' AND s.is_visible)
    ),
    -- Block 20: Vital signs
    sec_20_entries AS (
        SELECT COALESCE(
                   jsonb_agg(
                       jsonb_build_object(
                           'commonClinicalMetadata', nps.clinical_metadata(ce),
                           'nps2001VitalSign',                    vs.vital_sign,
                           'nps2001VitalSignOther',               vs.vital_sign_other,
                           'nps2002ValueRaw',                     vs.value_raw,
                           'nps2002ValueNumeric',                 vs.value_numeric,
                           'nps2002BpSystolic',                   vs.bp_systolic,
                           'nps2002BpDiastolic',                  vs.bp_diastolic,
                           'nps2002ValueUnknownReason',           vs.value_unknown_reason,
                           'nps2003Unit',                         vs.unit,
                           'nps2003UnitOther',                    vs.unit_other,
                           'nps2004MeasurementDateRaw',           vs.measurement_date_raw,
                           'nps2004MeasurementDateTime',          vs.measurement_date_time,
                           'nps2004MeasurementDateUnknownReason', vs.measurement_date_unknown_reason,
                           'nps2005BodyPosition',                 vs.body_position,
                           'nps2006MeasurementMethod',            vs.measurement_method
                       )
                       ORDER BY vs.measurement_date_time DESC NULLS LAST,
                                vs.vital_sign ASC, ce.entry_uid
                   ),
                   '[]'::jsonb
               ) AS entries
          FROM nps.vital_sign vs
          JOIN nps.clinical_entry ce ON ce.entry_uid = vs.entry_uid
         WHERE vs.patient_uid = v_resolved_patient_uid
           AND ce.record_lifecycle_status IN ('Active', 'Corrected')
           AND EXISTS (SELECT 1 FROM sec_status s WHERE s.block_code = 'NPS-20' AND s.is_visible)
    )
    SELECT jsonb_build_object(
        'schemaProfile', 'Sierra Leone National Patient Summary (Pre-FHIR Reference)',
        'standardsNote', 'Proposed Sierra Leone local adaptation informed by ISO 27269:2025; not an ISO or FHIR/IPS conformity claim.',

        -- Block 01: Document & provenance (NPS-01-01 to NPS-01-17)
        'documentAndProvenance', jsonb_build_object(
            'nps0101DocumentId',            v_doc_row.document_id,
            'nps0102DocumentVersion',       v_doc_row.document_version,
            'nps0103PatientId',             v_doc_row.shared_patient_id,
            'nps0104SourceFacilityId',      v_doc_row.source_facility_id,
            'nps0105SourceEmr',             v_doc_row.source_emr,
            'nps0106GeneratedDateTime',     v_doc_row.generated_date_time,
            'nps0107DocumentStatus',        v_doc_row.document_status,
            'nps0108AuthorAssembler',       v_doc_row.author_assembler,
            'nps0109GenerationMethod',      v_doc_row.generation_method,
            'nps0110Language',              v_doc_row.language_choice,
            'nps0110LanguageOther',         v_doc_row.language_other,
            'nps0111Confidentiality',       v_doc_row.confidentiality,
            'nps0112ClinicalPeriod',        jsonb_build_object(
                                                'startDate', v_doc_row.clinical_period_start,
                                                'endDate',   v_doc_row.clinical_period_end
                                            ),
            'nps0113Attester',              v_doc_row.attester,
            'nps0114AttestationDateTime',   v_doc_row.attestation_date_time,
            'nps0115Custodian',             v_doc_row.custodian,
            'nps0116ReceivedDateTime',      v_doc_row.received_date_time,
            'nps0117SourceRecordReference', v_doc_row.source_record_reference,
            'supersedesDocumentId', (
                SELECT prior.document_id FROM nps.summary_document prior
                WHERE prior.document_uid = v_doc_row.supersedes_document_uid
                  AND (prior.confidentiality = 'Normal' OR COALESCE(p_include_restricted, FALSE))
            )
        ),

        -- Block 02: Patient & contacts (NPS-02-01 to NPS-02-15)
        'patientAndContacts', (
            SELECT jsonb_build_object(
                'nps0201PatientName',             d.nps_02_01_patient_name,
                'nps0202SourcePatientIdentifier', jsonb_build_object(
                    'identifierValue',   d.nps_02_02_source_patient_id,
                    'issuingFacilityId', d.nps_02_02_issuing_facility_id,
                    'issuingSystem',     d.nps_02_02_issuing_system
                ),
                'nps0203OtherPatientIdentifiers', CASE WHEN p_include_restricted THEN d.nps_02_03_other_identifiers_json ELSE '[]'::jsonb END,
                'nps0204Sex',                     d.nps_02_04_sex,
                'nps0205DateOfBirth',             jsonb_build_object(
                    'raw',       d.nps_02_05_date_of_birth_raw,
                    'exactDate', d.nps_02_05_date_of_birth_exact,
                    'precision', d.nps_02_05_dob_precision
                ),
                'nps0206AgeAtAssessment',         CASE
                    WHEN d.nps_02_06_age_value IS NOT NULL THEN jsonb_build_object(
                        'value', d.nps_02_06_age_value,
                        'unit',  d.nps_02_06_age_unit
                    )
                    ELSE NULL
                END,
                'nps0207DateOfAgeAssessment',     d.nps_02_07_age_assessment_date,
                'nps0208EstimatedBirthDate',      d.nps_02_08_estimated_birth_date,
                'nps0209VitalStatus',             d.nps_02_09_vital_status,
                'nps0210PhoneNumber',             d.nps_02_10_phone_number,
                'nps0211District',                d.nps_02_11_district,
                'nps0212Chiefdom',                d.nps_02_12_chiefdom,
                'nps0213Locality',                d.nps_02_13_locality,
                'nps0214EmergencyContacts',       CASE WHEN p_include_restricted THEN d.nps_02_14_emergency_contacts ELSE '[]'::jsonb END,
                'nps0215ContactPermission',       d.nps_02_15_contact_permission,
                'recordStatus',                   d.record_status
            )
            FROM nps.extract_patient_demographics(
                v_patient_row.primary_source_facility_id,
                v_patient_row.primary_source_patient_id,
                v_patient_row.primary_source_system,
                p_include_restricted
            ) d
        ),

        -- Block 03: Section completeness summary (NPS-03-01 to NPS-03-06)
        'sectionCompleteness', (
            SELECT COALESCE(
                       jsonb_agg(
                           jsonb_build_object(
                               'npsBlockCode',                      s.block_code,
                               'nps0301NpsBlock',                   s.block_name,
                               'priorityLevel',                     s.priority_level,
                               'nps0302SectionInformationStatus',   s.info_status,
                               'nps0303ExtractionStatus',           s.extraction_status,
                               'nps0304LastAssessedDate',           s.last_assessed_date,
                               'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                               'nps0305ReasonUnavailableOther',     s.reason_unavailable_other,
                               'nps0306SectionAccessRestriction',   s.access_restriction
                           )
                           ORDER BY s.block_code ASC
                       ),
                       '[]'::jsonb
                   )
              FROM sec_status s
        ),

        -- Clinical Summary Sections (Blocks NPS-05 through NPS-20)
        'clinicalSections', jsonb_build_object(
            'problemsAndDiagnoses', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_05_entries e WHERE s.block_code = 'NPS-05'
            ),
            'allergiesAndIntolerances', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_06_entries e WHERE s.block_code = 'NPS-06'
            ),
            'medicationSummary', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_07_entries e WHERE s.block_code = 'NPS-07'
            ),
            'immunizations', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_08_entries e WHERE s.block_code = 'NPS-08'
            ),
            'laboratoryAndImagingResults', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'reports',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_09_entries e WHERE s.block_code = 'NPS-09'
            ),
            'historyOfProcedures', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_10_entries e WHERE s.block_code = 'NPS-10'
            ),
            'medicalDevices', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_11_entries e WHERE s.block_code = 'NPS-11'
            ),
            'alerts', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_12_entries e WHERE s.block_code = 'NPS-12'
            ),
            'advanceDirectives', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_13_entries e WHERE s.block_code = 'NPS-13'
            ),
            'functionalStatus', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_14_entries e WHERE s.block_code = 'NPS-14'
            ),
            'pregnancyHistory', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          '[]'::jsonb,
                    'nps1501PregnancyHistoryBlock',     'Pending approved maternal-health data dictionary',
                    'programmeGuidance',                'Source document does not define detailed fields; do not invent a dataset'
                )
                FROM sec_status s WHERE s.block_code = 'NPS-15'
            ),
            'socialHistory', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_16_entries e WHERE s.block_code = 'NPS-16'
            ),
            'carePlanAndFollowUp', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_17_entries e WHERE s.block_code = 'NPS-17'
            ),
            'pastProblems', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_18_entries e WHERE s.block_code = 'NPS-18'
            ),
            'patientStory', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_19_entries e WHERE s.block_code = 'NPS-19'
            ),
            'vitalSigns', (
                SELECT jsonb_build_object(
                    'blockCode',                        s.block_code,
                    'nps0302SectionInformationStatus',  s.info_status,
                    'nps0303ExtractionStatus',          s.extraction_status,
                    'nps0304LastAssessedDate',          s.last_assessed_date,
                    'nps0305ReasonInformationUnavailable', s.reason_unavailable,
                    'nps0306SectionAccessRestriction',  s.access_restriction,
                    'entries',                          e.entries
                )
                FROM sec_status s CROSS JOIN sec_20_entries e WHERE s.block_code = 'NPS-20'
            )
        ),

        'lastUpdatedAt', (
            SELECT updated_at FROM nps.patient_revision WHERE patient_uid = v_resolved_patient_uid
        )
    )
    INTO v_summary_json;

    RETURN v_summary_json;
END;
$$;

COMMENT ON FUNCTION nps.assemble_patient_summary(UUID, BOOLEAN, UUID) IS
    'Assembles a complete, fan-out-free Sierra Leone National Patient Summary JSONB document (NPS-01 through NPS-20) for the proposed internal NPS patient_uid.';

COMMIT;
