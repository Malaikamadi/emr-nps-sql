-- Run all migrations as the dedicated owner. Role bootstrap requires CREATEROLE
-- during installation or precreated roles with appropriately delegated admin.
BEGIN;

DO $$
DECLARE v_role TEXT;
BEGIN
    FOREACH v_role IN ARRAY ARRAY[
        'nps_api', 'nps_ingest', 'nps_publisher', 'nps_sync_sender', 'nps_sync_receiver',
        'nps_sync_operator', 'nps_quality', 'nps_access_admin', 'nps_auditor'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', v_role);
        ELSIF EXISTS (
            SELECT 1 FROM pg_roles WHERE rolname = v_role AND
              (rolcanlogin OR rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls)
        ) THEN RAISE EXCEPTION 'Unexpected privileged role name collision: %', v_role;
        END IF;
    END LOOP;
END;
$$;

CREATE TABLE nps.patient_access (
    login_name NAME NOT NULL,
    actor_subject TEXT NOT NULL CHECK (NULLIF(btrim(actor_subject), '') IS NOT NULL),
    patient_uid UUID NOT NULL REFERENCES nps.patient,
    purpose_of_use TEXT NOT NULL CHECK (NULLIF(btrim(purpose_of_use), '') IS NOT NULL),
    actor_facility_id VARCHAR(128) NOT NULL,
    may_view_restricted BOOLEAN NOT NULL DEFAULT FALSE,
    valid_until TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (login_name, actor_subject, patient_uid, purpose_of_use, actor_facility_id)
);

CREATE TABLE nps.security_audit_log (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id UUID NOT NULL,
    login_name NAME NOT NULL,
    actor_subject TEXT NOT NULL,
    patient_uid UUID REFERENCES nps.patient,
    purpose_of_use TEXT NOT NULL,
    actor_facility_id VARCHAR(128) NOT NULL,
    requested_block VARCHAR(16),
    access_outcome TEXT NOT NULL CHECK (access_outcome IN ('Granted', 'Denied')),
    restricted_scope BOOLEAN NOT NULL,
    accessed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX security_audit_patient_time ON nps.security_audit_log (patient_uid, accessed_at DESC);

CREATE TABLE nps.sync_principal (
    login_name NAME NOT NULL,
    source_facility_id VARCHAR(128) NOT NULL,
    source_system VARCHAR(150) NOT NULL,
    direction TEXT NOT NULL CHECK (direction IN ('Send', 'Receive')),
    PRIMARY KEY (login_name, source_facility_id, source_system, direction),
    CHECK ((direction = 'Send' AND source_system = '') OR
           (direction = 'Receive' AND NULLIF(btrim(source_system), '') IS NOT NULL))
);

-- Only this interface is executable by nps_api. The authenticated Java service
-- supplies identity from verified claims and trusted context. The database
-- requires a current matching entitlement for the login, subject and patient.
CREATE FUNCTION nps.read_authorised_patient_summary(
    p_source_facility VARCHAR, p_source_system VARCHAR, p_source_patient_id VARCHAR,
    p_actor_subject TEXT, p_actor_facility VARCHAR, p_purpose TEXT, p_request_id UUID,
    p_section VARCHAR DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_patient UUID;
    v_restricted BOOLEAN := FALSE;
    v_summary JSONB;
    v_key TEXT;
BEGIN
    IF p_request_id IS NULL OR NULLIF(btrim(p_actor_subject), '') IS NULL
       OR NULLIF(btrim(p_purpose), '') IS NULL OR NULLIF(btrim(p_actor_facility), '') IS NULL
       OR length(p_actor_subject) > 256 OR length(p_purpose) > 64 OR length(p_actor_facility) > 128
       OR length(p_section) > 16
    THEN RAISE EXCEPTION 'Invalid access context'; END IF;

    v_patient := nps.resolve_patient_uid(p_source_facility, p_source_patient_id, p_source_system);
    SELECT may_view_restricted INTO v_restricted FROM nps.patient_access
    WHERE login_name = session_user AND actor_subject = p_actor_subject AND patient_uid = v_patient
      AND purpose_of_use = p_purpose AND actor_facility_id = p_actor_facility
      AND valid_until > clock_timestamp()
    FOR SHARE;
    IF FOUND THEN
        v_summary := nps.get_patient_summary(v_patient, v_restricted);
        v_key := CASE p_section
            WHEN 'NPS-05' THEN 'problemsAndDiagnoses'
            WHEN 'NPS-06' THEN 'allergiesAndIntolerances'
            WHEN 'NPS-07' THEN 'medicationSummary'
            WHEN 'NPS-08' THEN 'immunizations'
            WHEN 'NPS-09' THEN 'laboratoryAndImagingResults'
            WHEN 'NPS-10' THEN 'historyOfProcedures'
            WHEN 'NPS-11' THEN 'medicalDevices'
            WHEN 'NPS-12' THEN 'alerts'
            WHEN 'NPS-13' THEN 'advanceDirectives'
            WHEN 'NPS-14' THEN 'functionalStatus'
            WHEN 'NPS-15' THEN 'pregnancyHistory'
            WHEN 'NPS-16' THEN 'socialHistory'
            WHEN 'NPS-17' THEN 'carePlanAndFollowUp'
            WHEN 'NPS-18' THEN 'pastProblems'
            WHEN 'NPS-19' THEN 'patientStory'
            WHEN 'NPS-20' THEN 'vitalSigns' END;
        IF p_section = 'NPS-01' THEN v_summary := v_summary -> 'documentAndProvenance';
        ELSIF p_section = 'NPS-02' THEN v_summary := v_summary -> 'patientAndContacts';
        ELSIF p_section = 'NPS-03' THEN v_summary := v_summary -> 'sectionCompleteness';
        ELSIF p_section = 'NPS-04' AND v_summary IS NOT NULL THEN
            SELECT COALESCE(jsonb_agg(item.value -> 'commonClinicalMetadata' ORDER BY s.key, item.ordinality), '[]'::JSONB)
            INTO v_summary
            FROM jsonb_each(v_summary -> 'clinicalSections') s
            CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.value -> 'entries', s.value -> 'reports'))
                WITH ORDINALITY AS item(value, ordinality)
            WHERE item.value ? 'commonClinicalMetadata';
        ELSIF p_section IS NOT NULL THEN v_summary := v_summary #> ARRAY['clinicalSections', v_key];
        END IF;
    END IF;

    INSERT INTO nps.security_audit_log (
        request_id, login_name, actor_subject, patient_uid, purpose_of_use, actor_facility_id,
        requested_block, access_outcome, restricted_scope
    ) VALUES (
        p_request_id, session_user, p_actor_subject, v_patient, p_purpose, p_actor_facility,
        p_section, CASE WHEN v_summary IS NULL THEN 'Denied' ELSE 'Granted' END,
        v_summary IS NOT NULL AND COALESCE(v_restricted, FALSE)
    );
    RETURN v_summary;
END;
$$;

CREATE FUNCTION nps.claim_authorised_sync_event(p_facility VARCHAR)
RETURNS SETOF nps.sync_outbox_event
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM 1 FROM nps.sync_principal WHERE login_name = session_user
        AND source_facility_id = p_facility AND direction = 'Send' FOR SHARE;
    IF NOT FOUND THEN RETURN; END IF;
    RETURN QUERY SELECT * FROM nps.claim_sync_event(p_facility);
END;
$$;

CREATE FUNCTION nps.finish_authorised_sync_event(
    p_facility VARCHAR, p_event UUID, p_claim_token UUID, p_receipt TEXT,
    p_error_code TEXT DEFAULT NULL, p_permanent BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM 1 FROM nps.sync_principal WHERE login_name = session_user
        AND source_facility_id = p_facility AND direction = 'Send' FOR SHARE;
    IF NOT FOUND THEN RETURN FALSE; END IF;
    RETURN nps.finish_sync_event(p_facility, p_event, p_claim_token, p_receipt, p_error_code, p_permanent);
END;
$$;

CREATE FUNCTION nps.receive_authorised_sync_event(
    p_facility VARCHAR, p_system VARCHAR, p_event UUID, p_source_seq BIGINT,
    p_patient UUID, p_document UUID, p_version INTEGER, p_base INTEGER,
    p_operation TEXT, p_payload JSONB, p_digest TEXT
) RETURNS TABLE (outcome TEXT, receipt_uid UUID, received_at TIMESTAMPTZ)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM 1 FROM nps.sync_principal WHERE login_name = session_user
        AND source_facility_id = p_facility AND source_system = p_system AND direction = 'Receive' FOR SHARE;
    IF NOT FOUND THEN
        RETURN QUERY SELECT 'Rejected'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;
    RETURN QUERY SELECT * FROM nps.receive_sync_event(
        p_facility, p_system, p_event, p_source_seq, p_patient, p_document, p_version,
        p_base, p_operation, p_payload, p_digest
    );
END;
$$;

ALTER FUNCTION nps.publish_patient_summary(UUID, BIGINT, BOOLEAN) SECURITY DEFINER;
ALTER FUNCTION nps.invalidate_released_summary(UUID) SECURITY DEFINER;
ALTER FUNCTION nps.requeue_failed_event(VARCHAR, UUID) SECURITY DEFINER;
ALTER FUNCTION nps.track_patient_revision() SECURITY DEFINER;

REVOKE ALL ON SCHEMA nps FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA nps FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA nps FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA nps FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

GRANT USAGE ON SCHEMA nps TO nps_api, nps_ingest, nps_publisher, nps_sync_sender,
    nps_sync_receiver, nps_sync_operator, nps_quality, nps_access_admin, nps_auditor;
GRANT EXECUTE ON FUNCTION nps.read_authorised_patient_summary(VARCHAR, VARCHAR, VARCHAR, TEXT, VARCHAR, TEXT, UUID, VARCHAR)
    TO nps_api;
GRANT EXECUTE ON FUNCTION nps.claim_authorised_sync_event(VARCHAR),
    nps.finish_authorised_sync_event(VARCHAR, UUID, UUID, TEXT, TEXT, BOOLEAN) TO nps_sync_sender;
GRANT EXECUTE ON FUNCTION nps.receive_authorised_sync_event(VARCHAR, VARCHAR, UUID, BIGINT, UUID, UUID, INTEGER,
    INTEGER, TEXT, JSONB, TEXT) TO nps_sync_receiver;
GRANT EXECUTE ON FUNCTION nps.publish_patient_summary(UUID, BIGINT, BOOLEAN),
    nps.invalidate_released_summary(UUID) TO nps_publisher;
GRANT EXECUTE ON FUNCTION nps.requeue_failed_event(VARCHAR, UUID) TO nps_sync_operator;
GRANT SELECT ON nps.validation_issues, nps.block_catalog, nps.data_dictionary_element TO nps_quality;
GRANT SELECT ON nps.security_audit_log TO nps_auditor;
GRANT SELECT, INSERT, UPDATE, DELETE ON nps.patient_access, nps.sync_principal TO nps_access_admin;

-- Trusted source adapter. It writes the normalized reference schema and must
-- enforce source-scoped access itself. It has no transport or API entitlement.
GRANT SELECT, INSERT, UPDATE ON nps.patient, nps.patient_identifier, nps.patient_contact_person,
    nps.clinical_encounter, nps.summary_document, nps.section_completeness, nps.clinical_entry,
    nps.problem_diagnosis, nps.allergy_intolerance, nps.medication_summary, nps.immunization,
    nps.diagnostic_report, nps.diagnostic_result_item, nps.procedure_history, nps.medical_device,
    nps.clinical_alert, nps.advance_directive, nps.functional_status, nps.social_history,
    nps.care_plan, nps.care_plan_action, nps.past_problem, nps.patient_story, nps.vital_sign TO nps_ingest;
GRANT SELECT ON nps.block_catalog, nps.data_dictionary_element, nps.patient_revision TO nps_ingest;
GRANT SELECT (document_uid) ON nps.summary_release TO nps_ingest;
GRANT USAGE ON SEQUENCE nps.sync_change_seq TO nps_ingest;
GRANT SELECT ON nps.patient_revision TO nps_publisher;

COMMIT;
