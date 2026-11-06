-- Transactional release, ordered outbox, and receiving-side snapshot registry.
BEGIN;

CREATE TABLE nps.sync_checkpoint (
    source_facility_id VARCHAR(128) PRIMARY KEY,
    last_acknowledged_change_seq BIGINT NOT NULL DEFAULT 0,
    last_acknowledged_at TIMESTAMPTZ
);

CREATE TABLE nps.sync_outbox_event (
    change_seq BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id UUID NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    source_facility_id VARCHAR(128) NOT NULL REFERENCES nps.sync_checkpoint,
    source_system VARCHAR(150) NOT NULL,
    patient_uid UUID NOT NULL REFERENCES nps.patient,
    document_uid UUID NOT NULL REFERENCES nps.summary_release,
    record_version INTEGER NOT NULL CHECK (record_version > 0),
    base_version INTEGER NOT NULL CHECK (base_version >= 0),
    operation_type TEXT NOT NULL CHECK (operation_type IN ('PUBLISH', 'INVALIDATE')),
    payload JSONB NOT NULL,
    payload_sha256 TEXT NOT NULL,
    transfer_status TEXT NOT NULL DEFAULT 'Pending'
        CHECK (transfer_status IN ('Pending', 'In_Flight', 'Retry', 'Failed', 'Acknowledged', 'Cancelled')),
    attempt_count INTEGER NOT NULL DEFAULT 0,
    claim_token UUID,
    lease_until TIMESTAMPTZ,
    next_attempt_at TIMESTAMPTZ,
    acknowledged_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    remote_receipt_ref TEXT,
    last_error_code TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (document_uid, operation_type),
    CHECK ((operation_type = 'PUBLISH' AND record_version > base_version) OR
           (operation_type = 'INVALIDATE' AND record_version = base_version)),
    CHECK ((transfer_status = 'In_Flight') = (claim_token IS NOT NULL AND lease_until IS NOT NULL)),
    CHECK ((transfer_status = 'Acknowledged') =
           (acknowledged_at IS NOT NULL AND remote_receipt_ref IS NOT NULL)),
    CHECK ((transfer_status = 'Cancelled') = (cancelled_at IS NOT NULL)),
    CHECK (transfer_status <> 'Cancelled' OR (operation_type = 'PUBLISH' AND attempt_count = 0))
);
CREATE INDEX sync_outbox_facility_keyset ON nps.sync_outbox_event (source_facility_id, change_seq);
CREATE INDEX sync_outbox_patient_version ON nps.sync_outbox_event
    (patient_uid, source_facility_id, source_system, record_version DESC);
CREATE UNIQUE INDEX sync_receipt_ref_unique ON nps.sync_outbox_event
    (source_facility_id, remote_receipt_ref) WHERE remote_receipt_ref IS NOT NULL;

CREATE TABLE nps.sync_attempt (
    event_id UUID NOT NULL REFERENCES nps.sync_outbox_event (event_id),
    attempt_no INTEGER NOT NULL,
    claim_token UUID NOT NULL UNIQUE,
    started_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    finished_at TIMESTAMPTZ,
    outcome TEXT NOT NULL DEFAULT 'In_Flight'
        CHECK (outcome IN ('In_Flight', 'Expired', 'Retry', 'Failed', 'Acknowledged')),
    error_code TEXT,
    PRIMARY KEY (event_id, attempt_no)
);

CREATE TABLE nps.sync_inbox_receipt (
    receipt_uid UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source_facility_id VARCHAR(128) NOT NULL,
    source_system VARCHAR(150) NOT NULL,
    event_id UUID NOT NULL,
    source_change_seq BIGINT NOT NULL CHECK (source_change_seq > 0),
    source_patient_uid UUID NOT NULL,
    source_document_uid UUID NOT NULL,
    record_version INTEGER NOT NULL CHECK (record_version > 0),
    base_version INTEGER NOT NULL CHECK (base_version >= 0),
    operation_type TEXT NOT NULL CHECK (operation_type IN ('PUBLISH', 'INVALIDATE')),
    payload JSONB NOT NULL,
    payload_sha256 TEXT NOT NULL,
    -- NPS-01-16: Hub-assigned receipt timestamp. Sender payload stays immutable.
    received_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (source_facility_id, source_system, event_id),
    UNIQUE (source_facility_id, source_system, source_change_seq),
    UNIQUE (source_facility_id, source_system, source_document_uid, operation_type)
);
CREATE INDEX sync_inbox_stream ON nps.sync_inbox_receipt
    (source_facility_id, source_system, source_patient_uid, source_change_seq DESC);

CREATE TABLE nps.sync_conflict_log (
    source_facility_id VARCHAR(128) NOT NULL,
    source_system VARCHAR(150) NOT NULL,
    event_id UUID NOT NULL,
    source_patient_uid UUID NOT NULL,
    reason_code TEXT NOT NULL,
    incoming_sha256 TEXT NOT NULL,
    detected_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    resolved_at TIMESTAMPTZ,
    PRIMARY KEY (source_facility_id, source_system, event_id)
);

-- The revision is transactional and patient-scoped. A publisher locks the same
-- row before checking the expected revision and assembling a snapshot.
CREATE FUNCTION nps.track_patient_revision() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_patient UUID;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.patient_uid IS DISTINCT FROM OLD.patient_uid THEN
        RAISE EXCEPTION 'Patient reassignment requires an explicit reconciliation';
    END IF;
    IF TG_OP = 'DELETE' THEN v_patient := OLD.patient_uid;
    ELSE v_patient := NEW.patient_uid;
    END IF;
    INSERT INTO nps.patient_revision AS r (patient_uid) VALUES (v_patient)
    ON CONFLICT (patient_uid) DO UPDATE SET revision = r.revision + 1, updated_at = clock_timestamp();
    RETURN NULL;
END;
$$;

DO $$
DECLARE v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'patient', 'patient_identifier', 'patient_contact_person', 'summary_document',
        'section_completeness', 'clinical_entry', 'clinical_encounter', 'problem_diagnosis',
        'allergy_intolerance', 'medication_summary', 'immunization', 'diagnostic_report',
        'diagnostic_result_item', 'procedure_history', 'medical_device', 'clinical_alert',
        'advance_directive', 'functional_status', 'pregnancy_history_reserved', 'social_history',
        'care_plan', 'care_plan_action', 'past_problem', 'patient_story', 'vital_sign'
    ] LOOP
        EXECUTE format('CREATE TRIGGER track_patient_revision AFTER INSERT OR UPDATE%s ON nps.%I
            FOR EACH ROW EXECUTE FUNCTION nps.track_patient_revision()',
            CASE WHEN v_table = 'patient' THEN '' ELSE ' OR DELETE' END, v_table);
    END LOOP;
END;
$$;

CREATE FUNCTION nps.payload_digest(p_payload JSONB) RETURNS TEXT
LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog, pg_temp
AS $$ SELECT encode(sha256(convert_to(p_payload::text, 'UTF8')), 'hex') $$;

-- Private. The facility mutex is held through commit. Outbox IDs are allocated
-- after acquiring it, so an older event cannot become visible behind a cursor.
CREATE FUNCTION nps.enqueue_release(
    p_document nps.summary_document, p_operation TEXT, p_payload JSONB
) RETURNS UUID
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_base INTEGER; v_event UUID;
BEGIN
    INSERT INTO nps.sync_checkpoint (source_facility_id) VALUES (p_document.source_facility_id)
    ON CONFLICT DO NOTHING;
    PERFORM 1 FROM nps.sync_checkpoint
    WHERE source_facility_id = p_document.source_facility_id FOR UPDATE;

    SELECT COALESCE(max(record_version), 0) INTO v_base
    FROM nps.sync_outbox_event
    WHERE patient_uid = p_document.patient_uid AND source_facility_id = p_document.source_facility_id
      AND source_system = p_document.source_emr AND operation_type = 'PUBLISH'
      AND transfer_status <> 'Cancelled';

    INSERT INTO nps.sync_outbox_event (
        source_facility_id, source_system, patient_uid, document_uid, record_version, base_version,
        operation_type, payload, payload_sha256
    ) VALUES (
        p_document.source_facility_id, p_document.source_emr, p_document.patient_uid,
        p_document.document_uid, p_document.version_number, v_base, p_operation,
        p_payload, nps.payload_digest(p_payload)
    ) RETURNING event_id INTO v_event;
    RETURN v_event;
END;
$$;

-- NPS-01: Persist the exact assembled versions. Export is a separate, explicit
-- policy decision and can queue only a standard payload from a normal document.
CREATE FUNCTION nps.publish_patient_summary(
    p_document_uid UUID, p_expected_revision BIGINT, p_queue_for_shr BOOLEAN DEFAULT FALSE
) RETURNS UUID
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_doc nps.summary_document%ROWTYPE;
    v_revision BIGINT;
    v_standard JSONB;
    v_restricted JSONB;
BEGIN
    SELECT * INTO STRICT v_doc FROM nps.summary_document WHERE document_uid = p_document_uid;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_doc.patient_uid::TEXT, 5417));
    SELECT revision INTO STRICT v_revision FROM nps.patient_revision
    WHERE patient_uid = v_doc.patient_uid FOR UPDATE;
    SELECT * INTO STRICT v_doc FROM nps.summary_document WHERE document_uid = p_document_uid;

    IF EXISTS (SELECT 1 FROM nps.summary_release WHERE document_uid = p_document_uid) THEN
        IF p_queue_for_shr IS DISTINCT FROM EXISTS (
            SELECT 1 FROM nps.sync_outbox_event
            WHERE document_uid = p_document_uid AND operation_type = 'PUBLISH'
        ) THEN RAISE EXCEPTION 'Release already recorded with different transport decision'; END IF;
        RETURN p_document_uid;
    END IF;
    IF v_revision IS DISTINCT FROM p_expected_revision THEN
        RAISE EXCEPTION 'Stale patient revision' USING ERRCODE = '40001';
    END IF;
    IF EXISTS (
        SELECT 1 FROM nps.section_completeness s
        JOIN nps.clinical_entry c ON c.patient_uid = s.patient_uid AND c.nps_block_code = s.nps_block_code
        WHERE s.document_uid = p_document_uid AND s.section_information_status = 'None known'
          AND c.record_lifecycle_status IN ('Active', 'Corrected')
    ) THEN RAISE EXCEPTION 'An explicit absence conflicts with a recorded entry'; END IF;
    IF EXISTS (
        SELECT 1 FROM nps.clinical_entry c JOIN nps.clinical_entry prior ON prior.entry_uid = c.replaces_entry_uid
        WHERE c.patient_uid = v_doc.patient_uid AND c.record_lifecycle_status IN ('Active', 'Corrected')
          AND prior.record_lifecycle_status IN ('Active', 'Corrected')
    ) THEN RAISE EXCEPTION 'An active correction has a visible predecessor'; END IF;
    IF EXISTS (
        SELECT 1 FROM nps.summary_document prior JOIN nps.summary_release r USING (document_uid)
        WHERE (prior.patient_uid, prior.source_facility_id, prior.source_emr)
            = (v_doc.patient_uid, v_doc.source_facility_id, v_doc.source_emr)
          AND prior.version_number >= v_doc.version_number
    ) THEN RAISE EXCEPTION 'Issued versions must increase'; END IF;
    IF NOT EXISTS (
        SELECT 1 FROM nps.patient p
        WHERE p.patient_uid = v_doc.patient_uid
          AND (p.primary_source_facility_id, p.primary_source_system) =
              (v_doc.source_facility_id, v_doc.source_emr)
          AND nps.resolve_patient_uid(p.primary_source_facility_id, p.primary_source_patient_id,
                                      p.primary_source_system) = p.patient_uid
    ) THEN RAISE EXCEPTION 'Release must use the canonical source stream'; END IF;

    v_restricted := nps.assemble_patient_summary(v_doc.patient_uid, TRUE, p_document_uid);
    v_standard := nps.assemble_patient_summary(v_doc.patient_uid, FALSE, p_document_uid);
    IF v_restricted IS NULL OR (COALESCE(p_queue_for_shr, FALSE) AND v_standard IS NULL) THEN
        RAISE EXCEPTION 'Document is unavailable for the requested release';
    END IF;
    INSERT INTO nps.summary_release (document_uid, patient_revision, standard_payload, restricted_payload)
    VALUES (p_document_uid, v_revision, v_standard, v_restricted);
    IF p_queue_for_shr THEN
        PERFORM nps.enqueue_release(v_doc, 'PUBLISH', v_standard);
    END IF;
    RETURN p_document_uid;
END;
$$;

CREATE FUNCTION nps.protect_issued_document() RETURNS TRIGGER
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended(OLD.patient_uid::TEXT, 5417));
    IF EXISTS (SELECT 1 FROM nps.summary_release WHERE document_uid = OLD.document_uid) THEN
        IF TG_OP = 'DELETE' THEN RAISE EXCEPTION 'Issued document is immutable'; END IF;
        IF (to_jsonb(OLD) - ARRAY['document_status','updated_at','change_seq']) IS DISTINCT FROM
           (to_jsonb(NEW) - ARRAY['document_status','updated_at','change_seq'])
           OR OLD.document_status <> 'Current'
           OR NEW.document_status NOT IN ('Superseded', 'Entered in error')
           OR (NEW.document_status = 'Entered in error' AND current_user <> TG_ARGV[0])
        THEN RAISE EXCEPTION 'Issued document is immutable'; END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

DO $$
BEGIN
    EXECUTE format('CREATE TRIGGER protect_issued_document BEFORE UPDATE OR DELETE ON nps.summary_document
        FOR EACH ROW EXECUTE FUNCTION nps.protect_issued_document(%L)', current_user);
END;
$$;

CREATE FUNCTION nps.invalidate_released_summary(p_document_uid UUID)
RETURNS VOID
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_doc nps.summary_document%ROWTYPE;
BEGIN
    SELECT * INTO STRICT v_doc FROM nps.summary_document WHERE document_uid = p_document_uid;
    PERFORM pg_advisory_xact_lock(hashtextextended(v_doc.patient_uid::TEXT, 5417));
    PERFORM 1 FROM nps.patient_revision WHERE patient_uid = v_doc.patient_uid FOR UPDATE;
    SELECT * INTO STRICT v_doc FROM nps.summary_document WHERE document_uid = p_document_uid;
    IF v_doc.document_status = 'Entered in error' THEN RETURN; END IF;
    IF v_doc.document_status <> 'Current' OR NOT EXISTS (
        SELECT 1 FROM nps.summary_release WHERE document_uid = p_document_uid
    ) THEN RAISE EXCEPTION 'Invalidation requires a current released document'; END IF;
    UPDATE nps.summary_document SET document_status = 'Entered in error' WHERE document_uid = p_document_uid;
    IF EXISTS (
        SELECT 1 FROM nps.sync_outbox_event
        WHERE document_uid = p_document_uid AND operation_type = 'PUBLISH'
    ) THEN
        PERFORM 1 FROM nps.sync_checkpoint WHERE source_facility_id = v_doc.source_facility_id FOR UPDATE;
        UPDATE nps.sync_outbox_event SET transfer_status = 'Cancelled', cancelled_at = clock_timestamp()
        WHERE document_uid = p_document_uid AND operation_type = 'PUBLISH'
          AND transfer_status = 'Pending' AND attempt_count = 0;
        IF FOUND THEN RETURN; END IF;
        PERFORM nps.enqueue_release(v_doc, 'INVALIDATE', jsonb_build_object('documentId', v_doc.document_id));
    END IF;
END;
$$;

-- Read the first unacknowledged event only. A delayed or permanently failed
-- head blocks later events. A lease makes a crashed worker recoverable.
CREATE FUNCTION nps.claim_sync_event(p_facility VARCHAR)
RETURNS SETOF nps.sync_outbox_event
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_cursor BIGINT; v_event nps.sync_outbox_event%ROWTYPE; v_now TIMESTAMPTZ;
BEGIN
    SELECT last_acknowledged_change_seq INTO v_cursor FROM nps.sync_checkpoint
    WHERE source_facility_id = p_facility FOR UPDATE;
    v_now := clock_timestamp();
    SELECT * INTO v_event FROM nps.sync_outbox_event
    WHERE source_facility_id = p_facility AND change_seq > v_cursor AND transfer_status <> 'Cancelled'
    ORDER BY change_seq LIMIT 1;
    IF NOT FOUND OR v_event.transfer_status IN ('Failed', 'Acknowledged')
       OR v_event.lease_until > v_now OR v_event.next_attempt_at > v_now THEN RETURN; END IF;

    IF v_event.transfer_status = 'In_Flight' THEN
        UPDATE nps.sync_attempt SET outcome = 'Expired', finished_at = v_now
        WHERE claim_token = v_event.claim_token;
    END IF;
    UPDATE nps.sync_outbox_event SET transfer_status = 'In_Flight',
        claim_token = gen_random_uuid(), lease_until = v_now + interval '2 minutes',
        next_attempt_at = NULL, attempt_count = attempt_count + 1
    WHERE event_id = v_event.event_id RETURNING * INTO v_event;
    INSERT INTO nps.sync_attempt (event_id, attempt_no, claim_token)
    VALUES (v_event.event_id, v_event.attempt_count, v_event.claim_token);
    RETURN NEXT v_event;
END;
$$;

CREATE FUNCTION nps.finish_sync_event(
    p_facility VARCHAR, p_event_id UUID, p_claim_token UUID,
    p_receipt TEXT, p_error_code TEXT DEFAULT NULL, p_permanent BOOLEAN DEFAULT FALSE
) RETURNS BOOLEAN
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_event nps.sync_outbox_event%ROWTYPE;
    v_cursor BIGINT;
    v_now TIMESTAMPTZ;
    v_status TEXT;
BEGIN
    IF p_receipt IS NOT NULL AND (length(p_receipt) > 128 OR btrim(p_receipt) = '' OR p_error_code IS NOT NULL)
       OR p_receipt IS NULL AND (p_error_code IS NULL OR p_error_code !~ '^[A-Z0-9_]{1,64}$')
    THEN RAISE EXCEPTION 'Supply a verified receipt or a sanitized failure code'; END IF;
    SELECT last_acknowledged_change_seq INTO v_cursor FROM nps.sync_checkpoint
    WHERE source_facility_id = p_facility FOR UPDATE;
    v_now := clock_timestamp();
    SELECT * INTO v_event FROM nps.sync_outbox_event
    WHERE source_facility_id = p_facility AND change_seq > v_cursor AND transfer_status <> 'Cancelled'
    ORDER BY change_seq LIMIT 1;
    IF NOT FOUND OR v_event.event_id IS DISTINCT FROM p_event_id
       OR v_event.transfer_status <> 'In_Flight' OR v_event.claim_token IS DISTINCT FROM p_claim_token
       OR v_event.lease_until <= v_now THEN RETURN FALSE; END IF;

    v_status := CASE WHEN p_receipt IS NOT NULL THEN 'Acknowledged'
                     WHEN p_permanent THEN 'Failed' ELSE 'Retry' END;
    UPDATE nps.sync_outbox_event SET transfer_status = v_status, claim_token = NULL, lease_until = NULL,
        remote_receipt_ref = p_receipt, last_error_code = p_error_code,
        acknowledged_at = CASE WHEN v_status = 'Acknowledged' THEN v_now END,
        next_attempt_at = CASE WHEN v_status = 'Retry'
            THEN v_now + make_interval(secs => LEAST(3600, 5 * power(2, LEAST(v_event.attempt_count - 1, 10)))) END
    WHERE event_id = p_event_id;
    UPDATE nps.sync_attempt SET outcome = v_status, finished_at = v_now, error_code = p_error_code
    WHERE claim_token = p_claim_token;
    IF v_status = 'Acknowledged' THEN
        UPDATE nps.sync_checkpoint SET last_acknowledged_change_seq = v_event.change_seq,
            last_acknowledged_at = v_now WHERE source_facility_id = p_facility;
    END IF;
    RETURN TRUE;
END;
$$;

CREATE FUNCTION nps.requeue_failed_event(p_facility VARCHAR, p_event_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    PERFORM 1 FROM nps.sync_checkpoint WHERE source_facility_id = p_facility FOR UPDATE;
    UPDATE nps.sync_outbox_event SET transfer_status = 'Retry', next_attempt_at = clock_timestamp()
    WHERE source_facility_id = p_facility AND event_id = p_event_id AND transfer_status = 'Failed';
    RETURN FOUND;
END;
$$;

-- Hub only. The Java transport binds the authenticated sender to the issuer and
-- validates the approved release profile. An accepted receipt stores a snapshot,
-- without automatically merging the clinical data into another patient's EMR.
CREATE FUNCTION nps.receive_sync_event(
    p_facility VARCHAR, p_system VARCHAR, p_event UUID, p_source_seq BIGINT,
    p_patient UUID, p_document UUID, p_version INTEGER, p_base INTEGER,
    p_operation TEXT, p_payload JSONB, p_digest TEXT
) RETURNS TABLE (outcome TEXT, receipt_uid UUID, received_at TIMESTAMPTZ)
LANGUAGE plpgsql SET search_path = pg_catalog, pg_temp
AS $$
DECLARE v_prior nps.sync_inbox_receipt%ROWTYPE; v_conflict TEXT; v_digest TEXT;
BEGIN
    v_digest := nps.payload_digest(p_payload);
    IF NULLIF(btrim(p_facility), '') IS NULL OR NULLIF(btrim(p_system), '') IS NULL
       OR p_event IS NULL OR p_patient IS NULL OR p_document IS NULL
       OR p_source_seq IS NULL OR p_source_seq < 1 OR p_version IS NULL OR p_version < 1
       OR p_base IS NULL OR p_base < 0 OR p_operation IS NULL OR p_operation NOT IN ('PUBLISH', 'INVALIDATE')
       OR p_digest IS NULL OR v_digest IS DISTINCT FROM p_digest
       OR jsonb_typeof(p_payload) IS DISTINCT FROM 'object'
    THEN RETURN QUERY SELECT 'Rejected'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ; RETURN; END IF;

    PERFORM pg_advisory_xact_lock(hashtextextended(jsonb_build_array(p_facility, p_system)::TEXT, 4907));
    SELECT * INTO v_prior FROM nps.sync_inbox_receipt r
    WHERE (r.source_facility_id, r.source_system, r.event_id) = (p_facility, p_system, p_event);
    IF FOUND THEN
        IF (v_prior.source_change_seq, v_prior.source_patient_uid, v_prior.source_document_uid,
            v_prior.record_version, v_prior.base_version, v_prior.operation_type, v_prior.payload_sha256)
           = (p_source_seq, p_patient, p_document, p_version, p_base, p_operation, p_digest) THEN
            RETURN QUERY SELECT 'Duplicate'::TEXT, v_prior.receipt_uid, v_prior.received_at;
            RETURN;
        END IF;
        v_conflict := 'IDEMPOTENCY_KEY_REUSED';
    ELSIF EXISTS (
        SELECT 1 FROM nps.sync_inbox_receipt r
        WHERE (r.source_facility_id, r.source_system) = (p_facility, p_system)
          AND (r.source_change_seq = p_source_seq OR
               (r.source_document_uid, r.operation_type) = (p_document, p_operation))
    ) THEN
        v_conflict := 'SOURCE_ID_REUSED';
    ELSE
        SELECT * INTO v_prior FROM nps.sync_inbox_receipt r
        WHERE (r.source_facility_id, r.source_system, r.source_patient_uid) = (p_facility, p_system, p_patient)
        ORDER BY r.source_change_seq DESC LIMIT 1;
        IF p_base <> COALESCE(v_prior.record_version, 0) OR p_source_seq <= COALESCE(v_prior.source_change_seq, 0)
           OR (p_operation = 'PUBLISH' AND p_version <= p_base)
           OR (p_operation = 'INVALIDATE' AND (
               p_version <> p_base OR v_prior.operation_type IS DISTINCT FROM 'PUBLISH'
               OR v_prior.source_document_uid IS DISTINCT FROM p_document
               OR (p_payload ->> 'documentId') IS DISTINCT FROM
                  (v_prior.payload #>> '{documentAndProvenance,nps0101DocumentId}')
               OR (p_payload - 'documentId') <> '{}'::JSONB
           )) THEN
            v_conflict := 'VERSION_OR_SEQUENCE_CONFLICT';
        ELSIF p_operation = 'PUBLISH' AND (
            (p_payload #>> '{documentAndProvenance,nps0104SourceFacilityId}') IS DISTINCT FROM p_facility
            OR (p_payload #>> '{documentAndProvenance,nps0105SourceEmr}') IS DISTINCT FROM p_system
            OR (p_payload #>> '{documentAndProvenance,nps0107DocumentStatus}') IS DISTINCT FROM 'Current'
            OR (p_payload #>> '{documentAndProvenance,nps0111Confidentiality}') IS DISTINCT FROM 'Normal'
            OR NULLIF(btrim(p_payload #>> '{documentAndProvenance,nps0101DocumentId}'), '') IS NULL
            OR jsonb_typeof(p_payload -> 'patientAndContacts') IS DISTINCT FROM 'object'
            OR jsonb_typeof(p_payload -> 'clinicalSections') IS DISTINCT FROM 'object'
        ) THEN
            RETURN QUERY SELECT 'Rejected'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ; RETURN;
        END IF;
    END IF;

    IF v_conflict IS NOT NULL THEN
        INSERT INTO nps.sync_conflict_log (
            source_facility_id, source_system, event_id, source_patient_uid, reason_code, incoming_sha256
        ) VALUES (p_facility, p_system, p_event, p_patient, v_conflict, p_digest)
        ON CONFLICT (source_facility_id, source_system, event_id) DO NOTHING;
        RETURN QUERY SELECT 'Conflict'::TEXT, NULL::UUID, NULL::TIMESTAMPTZ;
        RETURN;
    END IF;

    RETURN QUERY
    INSERT INTO nps.sync_inbox_receipt AS r (
        source_facility_id, source_system, event_id, source_change_seq, source_patient_uid,
        source_document_uid, record_version, base_version, operation_type, payload, payload_sha256
    ) VALUES (
        p_facility, p_system, p_event, p_source_seq, p_patient, p_document,
        p_version, p_base, p_operation, p_payload, p_digest
    ) RETURNING 'Accepted'::TEXT, r.receipt_uid, r.received_at;
END;
$$;

-- Internal UUID interface. A changed patient revision expires the release for
-- interactive reads until a new summary has been assembled and authorised.
CREATE FUNCTION nps.get_patient_summary(p_patient_id UUID, p_include_restricted BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE sql STABLE SET search_path = pg_catalog, pg_temp SET TimeZone = 'UTC'
AS $$
    SELECT (CASE WHEN p_include_restricted THEN s.restricted_payload ELSE s.standard_payload END)
        || jsonb_build_object('synchronisationStatus', jsonb_build_object(
            'state', COALESCE(o.transfer_status, 'Local_Only'),
            'acknowledgedAt', o.acknowledged_at
        ))
    FROM nps.patient p
    JOIN nps.patient_revision rev USING (patient_uid)
    JOIN nps.summary_document d ON d.patient_uid = p.patient_uid
      AND (d.source_facility_id, d.source_emr) = (p.primary_source_facility_id, p.primary_source_system)
    JOIN nps.summary_release s ON s.document_uid = d.document_uid AND s.patient_revision = rev.revision
    LEFT JOIN nps.sync_outbox_event o ON o.document_uid = d.document_uid AND o.operation_type = 'PUBLISH'
    WHERE p.patient_uid = p_patient_id AND p.record_status = 'Active' AND d.document_status = 'Current';
$$;

-- Private hub projection. Preserve the exact sender payload in the receipt and
-- add the receiver's timestamp (NPS-01-16) only when presenting the summary.
CREATE VIEW nps.received_current_summary AS
SELECT r.source_facility_id, r.source_system, r.source_patient_uid, r.source_document_uid,
       r.record_version, r.receipt_uid,
       jsonb_set(r.payload, '{documentAndProvenance,nps0116ReceivedDateTime}',
                 to_jsonb(to_char(r.received_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')), true) AS payload
FROM (
    SELECT DISTINCT ON (source_facility_id, source_system, source_patient_uid) *
    FROM nps.sync_inbox_receipt
    ORDER BY source_facility_id, source_system, source_patient_uid, source_change_seq DESC
) r
WHERE r.operation_type = 'PUBLISH';

COMMIT;
