-- Assertions use the synthetic fixtures. Changes in this test are rolled back.
BEGIN;

DO $$
DECLARE
    v_one UUID := '00000000-0000-4000-8000-000000000001';
    v_two UUID := '00000000-0000-4000-8000-000000000002';
    v_three UUID := '00000000-0000-4000-8000-000000000003';
    v_doc UUID := '00000000-0000-4000-8000-000000000021';
    v_summary JSONB;
    v_restricted JSONB;
    v_empty JSONB;
    v_name TEXT;
    v_count INTEGER;
    v_expected INTEGER;
    v_function RECORD;
BEGIN
    IF (SELECT count(*) FROM nps.data_dictionary_element) <> 149
       OR (SELECT count(*) FROM nps.block_catalog) <> 20 THEN RAISE EXCEPTION 'Dictionary count'; END IF;
    IF EXISTS (
        SELECT 1 FROM nps.data_dictionary_element e
        CROSS JOIN LATERAL regexp_split_to_table(e.target_columns, ',\s*') col(name)
        WHERE NOT EXISTS (
            SELECT 1 FROM information_schema.columns c
            WHERE c.table_schema || '.' || c.table_name = ANY (string_to_array(e.target_table, ' / '))
              AND c.column_name = col.name
        )
    ) THEN RAISE EXCEPTION 'Dictionary target column missing'; END IF;

    IF nps.resolve_patient_uid('TEST-F01', 'LOCAL-1', 'TEST-EMR') IS DISTINCT FROM v_one
       OR nps.resolve_patient_uid('TEST-F01', 'LOCAL-1', 'TEST-LEGACY') IS DISTINCT FROM v_two
       OR nps.resolve_patient_uid('TEST-F02', 'LOCAL-1', 'TEST-EMR') IS DISTINCT FROM v_three
       OR nps.resolve_patient_uid('TEST-F01', 'LOCAL-ALIAS', 'TEST-EMR') IS DISTINCT FROM v_one
       OR nps.resolve_patient_uid('TEST-F01', 'LOCAL-1', NULL) IS NOT NULL
       OR nps.resolve_patient_uid('TEST-F01', 'SYNTHETIC-SECONDARY-ID', 'TEST-REGISTRY') IS NOT NULL
    THEN RAISE EXCEPTION 'Issuer-scoped source identity'; END IF;

    -- Execute each private tabular extractor with the common required arguments.
    FOR v_function IN SELECT proname FROM pg_proc WHERE pronamespace = 'nps'::regnamespace
        AND proname LIKE 'extract_%' ORDER BY proname
    LOOP
        EXECUTE format('SELECT count(*) FROM nps.%I($1::varchar,$2::varchar,$3::varchar)', v_function.proname)
        INTO v_count USING 'TEST-F01', 'LOCAL-1', 'TEST-EMR';
        IF v_count < 1 THEN RAISE EXCEPTION 'Extractor returned no fixture rows: %', v_function.proname; END IF;
    END LOOP;

    v_summary := nps.get_patient_summary(v_one);
    v_restricted := nps.get_patient_summary(v_one, TRUE);
    v_empty := nps.get_patient_summary(v_two, TRUE);
    IF v_summary IS NULL OR v_empty IS NULL OR v_restricted IS NULL THEN RAISE EXCEPTION 'Summary missing'; END IF;
    IF jsonb_array_length(v_summary -> 'sectionCompleteness') <> 16
       OR (SELECT count(*) FROM jsonb_object_keys(v_summary -> 'clinicalSections')) <> 16
       OR v_summary #>> '{patientAndContacts,nps0205DateOfBirth,raw}' IS DISTINCT FROM '1999-03'
       OR v_summary #>> '{patientAndContacts,nps0205DateOfBirth,exactDate}' IS NOT NULL
       OR v_summary #>> '{documentAndProvenance,nps0116ReceivedDateTime}' IS NOT NULL
    THEN RAISE EXCEPTION 'Profile structure, partial date, or local receipt semantics'; END IF;

    FOR v_name, v_expected IN VALUES ('problemsAndDiagnoses', 2), ('allergiesAndIntolerances', 2),
        ('medicationSummary', 2), ('medicalDevices', 1), ('pregnancyHistory', 0), ('vitalSigns', 1)
    LOOP
        IF jsonb_array_length(v_summary #> ARRAY['clinicalSections', v_name, 'entries']) IS DISTINCT FROM v_expected
        THEN RAISE EXCEPTION 'Section cardinality: %', v_name; END IF;
    END LOOP;
    IF (SELECT count(*) FROM nps.extract_problems_diagnoses('TEST-F01', 'LOCAL-1', 'TEST-EMR', TRUE)) <> 4
       OR v_summary::TEXT LIKE '%TEST-ENTRY-501%' OR v_summary::TEXT LIKE '%TEST-ENTRY-504%'
       OR v_summary #>> '{clinicalSections,problemsAndDiagnoses,entries,0,commonClinicalMetadata,recordLifecycleStatus}'
          IS DISTINCT FROM 'Corrected'
       OR v_summary::TEXT NOT LIKE '%TEST-VISIT-1%' OR v_summary::TEXT NOT LIKE '%TEST-VISIT-2%'
       OR v_summary #>> '{clinicalSections,medicationSummary,entries,0,nps0702MedicationStatus}' IS DISTINCT FROM 'Unknown'
    THEN RAISE EXCEPTION 'Correction, clinical provenance, or medication uncertainty'; END IF;
    IF jsonb_array_length(v_summary #> '{clinicalSections,laboratoryAndImagingResults,reports}') IS DISTINCT FROM 2
       OR (SELECT sum(jsonb_array_length(report -> 'resultObservations'))
           FROM jsonb_array_elements(v_summary #> '{clinicalSections,laboratoryAndImagingResults,reports}') report)
          IS DISTINCT FROM 3::BIGINT
       OR v_summary::TEXT LIKE '%SYNTHETIC-WITHHELD-INTERPRETATION%'
       OR jsonb_array_length(v_summary #> '{clinicalSections,carePlanAndFollowUp,entries,0,plannedActions}')
          IS DISTINCT FROM 2
    THEN RAISE EXCEPTION 'Nested observations or care plan actions'; END IF;

    IF nps.get_patient_summary(v_two) IS NOT NULL OR nps.get_patient_summary(v_three) IS NOT NULL
       OR v_empty #>> '{clinicalSections,allergiesAndIntolerances,nps0302SectionInformationStatus}'
          IS DISTINCT FROM 'None known'
       OR v_empty #>> '{clinicalSections,problemsAndDiagnoses,nps0302SectionInformationStatus}'
          IS DISTINCT FROM 'Unknown'
       OR v_empty #>> '{clinicalSections,problemsAndDiagnoses,nps0305ReasonInformationUnavailable}'
          IS DISTINCT FROM 'Not recorded'
       OR v_summary::TEXT LIKE '%+00000000001%' OR v_summary::TEXT LIKE '%SYNTHETIC-SECONDARY-ID%'
       OR v_summary::TEXT LIKE '%Synthetic Contact%'
       OR v_summary::TEXT LIKE '%SYNTHETIC-RESTRICTED-STORY%'
       OR v_restricted::TEXT NOT LIKE '%SYNTHETIC-RESTRICTED-STORY%'
       OR v_restricted::TEXT NOT LIKE '%SYNTHETIC-SECONDARY-ID%'
       OR v_restricted::TEXT LIKE '%SYNTHETIC-WITHHELD-DIRECTIVE%'
    THEN RAISE EXCEPTION 'Absence or data minimisation'; END IF;

    BEGIN
        INSERT INTO nps.problem_diagnosis (entry_uid, patient_uid, problem_diagnosis_text, problem_status, diagnosis_certainty)
        VALUES ('00000000-0000-4000-8000-000000000601', v_two, 'Synthetic cross-patient row', 'Unknown', 'Unknown');
        RAISE EXCEPTION 'Cross-patient child unexpectedly accepted';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        UPDATE nps.section_completeness SET section_information_status = 'None known', extraction_status = 'Failed'
        WHERE document_uid = v_doc AND nps_block_code = 'NPS-06';
        RAISE EXCEPTION 'False absence unexpectedly accepted';
    EXCEPTION WHEN check_violation THEN NULL;
    END;

    IF NOT EXISTS (SELECT 1 FROM nps.validation_issues WHERE issue_code = 'CODE_UNVERIFIED')
       OR NOT EXISTS (SELECT 1 FROM nps.validation_issues WHERE issue_code = 'REQUIRED_SECTION_ASSESSMENT_MISSING'
                      AND patient_uid = v_two)
    THEN RAISE EXCEPTION 'Missing quality finding'; END IF;
    INSERT INTO nps.code_binding VALUES ('TEST-F01', 'TEST-EMR', 'NPS-04-10', 'SYNTHETIC-CATALOG', 'TEST-1');
    IF (SELECT count(*) FROM nps.validation_issues WHERE issue_code = 'CODE_UNSUPPORTED') <> 1
    THEN RAISE EXCEPTION 'Unsupported code check'; END IF;

    UPDATE nps.medication_summary SET frequency = 'Synthetic source update' WHERE patient_uid = v_one;
    IF nps.get_patient_summary(v_one) IS NOT NULL
       OR (SELECT standard_payload FROM nps.summary_release WHERE document_uid = v_doc)
          IS DISTINCT FROM (v_summary - 'synchronisationStatus')
    THEN RAISE EXCEPTION 'Stale release or changed archive'; END IF;
    BEGIN
        UPDATE nps.summary_document SET author_assembler = 'Synthetic overwrite' WHERE document_uid = v_doc;
        RAISE EXCEPTION 'Issued document overwrite unexpectedly accepted';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM <> 'Issued document is immutable' THEN RAISE; END IF;
    END;
END;
$$;

ROLLBACK;

BEGIN;
INSERT INTO nps.patient_access VALUES (
    session_user, 'synthetic-issuer/synthetic-subject', '00000000-0000-4000-8000-000000000001',
    'TEST-CARE', 'TEST-F01', FALSE, clock_timestamp() + interval '1 hour'
);

SET LOCAL ROLE nps_api;
DO $$
DECLARE v_payload JSONB;
BEGIN
    IF has_table_privilege(current_user, 'nps.patient', 'SELECT')
       OR has_function_privilege(current_user, 'nps.get_patient_summary(uuid,boolean)', 'EXECUTE')
    THEN RAISE EXCEPTION 'Public API role can bypass gate'; END IF;
    v_payload := nps.read_authorised_patient_summary('TEST-F01', 'TEST-EMR', 'LOCAL-1',
        'synthetic-issuer/synthetic-subject', 'TEST-F01', 'TEST-CARE', gen_random_uuid(), 'NPS-04');
    IF jsonb_array_length(v_payload) IS DISTINCT FROM 17 THEN RAISE EXCEPTION 'Authorised clinical metadata'; END IF;
    v_payload := nps.read_authorised_patient_summary('TEST-F01', 'TEST-EMR', 'LOCAL-1',
        'synthetic-issuer/synthetic-subject', 'TEST-F01', 'TEST-CARE', gen_random_uuid(), 'NPS-05');
    IF jsonb_array_length(v_payload -> 'entries') IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'Authorised block'; END IF;
    v_payload := nps.read_authorised_patient_summary('TEST-F01', 'TEST-LEGACY', 'LOCAL-1',
        'synthetic-issuer/synthetic-subject', 'TEST-F01', 'TEST-CARE', gen_random_uuid());
    IF v_payload IS NOT NULL THEN RAISE EXCEPTION 'Unauthorised cross-issuer read'; END IF;
END;
$$;
RESET ROLE;
DO $$
BEGIN
    IF (SELECT count(*) FROM nps.security_audit_log WHERE access_outcome = 'Granted') <> 2
       OR (SELECT count(*) FROM nps.security_audit_log WHERE access_outcome = 'Denied') <> 1
    THEN RAISE EXCEPTION 'Access audit'; END IF;
END;
$$;
ROLLBACK;
