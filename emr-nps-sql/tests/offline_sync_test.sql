-- Runs on the synthetic fixtures; all changes here are rolled back.
BEGIN;

DO $$
DECLARE
    v_patient UUID := '00000000-0000-4000-8000-000000000001';
    v_doc UUID := '00000000-0000-4000-8000-000000000021';
    v_doc2 UUID := '00000000-0000-4000-8000-000000000031';
    v_one nps.sync_outbox_event%ROWTYPE;
    v_retry nps.sync_outbox_event%ROWTYPE;
    v_two nps.sync_outbox_event%ROWTYPE;
    v_delete nps.sync_outbox_event%ROWTYPE;
    v_received RECORD;
    v_duplicate RECORD;
    v_change JSONB;
BEGIN
    PERFORM nps.publish_patient_summary(v_doc, 0, TRUE);
    IF (SELECT count(*) FROM nps.sync_outbox_event) <> 1 THEN RAISE EXCEPTION 'Duplicate release'; END IF;

    UPDATE nps.summary_document SET document_status = 'Superseded' WHERE document_uid = v_doc;
    INSERT INTO nps.summary_document (document_uid, patient_uid, document_id, document_version, version_number,
        shared_patient_id, source_facility_id, source_emr, generated_date_time, document_status,
        author_assembler, generation_method, language_choice, confidentiality, supersedes_document_uid)
    SELECT v_doc2, patient_uid, 'SYNTHETIC-DOC-1-V2', '2', 2, shared_patient_id, source_facility_id,
        source_emr, generated_date_time + interval '1 hour', 'Current', author_assembler,
        generation_method, language_choice, confidentiality, document_uid
    FROM nps.summary_document WHERE document_uid = v_doc;

    INSERT INTO nps.section_completeness (document_uid, patient_uid, nps_block_code, nps_block_name,
        section_information_status, extraction_status, section_access_restriction)
    SELECT v_doc2, patient_uid, nps_block_code, nps_block_name,
        section_information_status, extraction_status, section_access_restriction
    FROM nps.section_completeness WHERE document_uid = v_doc;
    BEGIN
        PERFORM nps.publish_patient_summary(v_doc2, 0, TRUE);
        RAISE EXCEPTION 'Stale release attempt unexpectedly succeeded';
    EXCEPTION WHEN serialization_failure THEN NULL;
    END;
    PERFORM nps.publish_patient_summary(v_doc2,
        (SELECT revision FROM nps.patient_revision WHERE patient_uid = v_patient), TRUE);

    SELECT * INTO v_one FROM nps.claim_sync_event('TEST-F01');
    IF v_one.document_uid IS DISTINCT FROM v_doc
       OR v_one.transfer_status IS DISTINCT FROM 'In_Flight'
       OR (SELECT last_acknowledged_change_seq FROM nps.sync_checkpoint WHERE source_facility_id = 'TEST-F01') <> 0
       OR EXISTS (SELECT 1 FROM nps.claim_sync_event('TEST-F01'))
    THEN RAISE EXCEPTION 'Head claim, lease or checkpoint'; END IF;

    IF nps.finish_sync_event('TEST-F01', v_one.event_id, v_one.claim_token, NULL, 'NETWORK_TIMEOUT') IS DISTINCT FROM TRUE
       OR EXISTS (SELECT 1 FROM nps.claim_sync_event('TEST-F01'))
       OR (SELECT last_acknowledged_change_seq FROM nps.sync_checkpoint WHERE source_facility_id = 'TEST-F01') <> 0
    THEN RAISE EXCEPTION 'Retryable failure advanced or bypassed the head'; END IF;

    -- Move the retry timer to the past to exercise backoff without sleeping.
    UPDATE nps.sync_outbox_event SET next_attempt_at = clock_timestamp() - interval '1 second'
    WHERE event_id = v_one.event_id;
    SELECT * INTO v_retry FROM nps.claim_sync_event('TEST-F01');
    IF v_retry.event_id IS DISTINCT FROM v_one.event_id
       OR v_retry.attempt_count IS DISTINCT FROM 2 OR v_retry.claim_token = v_one.claim_token
       OR v_retry.payload IS DISTINCT FROM v_one.payload
       OR nps.finish_sync_event('TEST-F01', v_one.event_id, v_one.claim_token, 'stale-receipt')
    THEN RAISE EXCEPTION 'Retry idempotency or stale claim token'; END IF;

    SELECT * INTO v_received FROM nps.receive_sync_event(v_retry.source_facility_id, v_retry.source_system,
        v_retry.event_id, v_retry.change_seq, v_retry.patient_uid, v_retry.document_uid, v_retry.record_version,
        v_retry.base_version, v_retry.operation_type, v_retry.payload, v_retry.payload_sha256);
    SELECT * INTO v_duplicate FROM nps.receive_sync_event(v_retry.source_facility_id, v_retry.source_system,
        v_retry.event_id, v_retry.change_seq, v_retry.patient_uid, v_retry.document_uid, v_retry.record_version,
        v_retry.base_version, v_retry.operation_type, v_retry.payload, v_retry.payload_sha256);
    IF v_received.outcome IS DISTINCT FROM 'Accepted' OR v_duplicate.outcome IS DISTINCT FROM 'Duplicate'
       OR v_duplicate.receipt_uid IS DISTINCT FROM v_received.receipt_uid
       OR v_duplicate.received_at IS DISTINCT FROM v_received.received_at
       OR v_received.received_at IS NULL
    THEN RAISE EXCEPTION 'Idempotent hub acceptance'; END IF;

    v_change := v_retry.payload || '{"testMarker":"changed"}'::JSONB;
    IF (SELECT outcome FROM nps.receive_sync_event(v_retry.source_facility_id, v_retry.source_system,
        v_retry.event_id, v_retry.change_seq, v_retry.patient_uid, v_retry.document_uid, v_retry.record_version,
        v_retry.base_version, v_retry.operation_type, v_change, v_retry.payload_sha256)) IS DISTINCT FROM 'Rejected'
    THEN RAISE EXCEPTION 'Transport digest'; END IF;
    IF (SELECT outcome FROM nps.receive_sync_event(v_retry.source_facility_id, v_retry.source_system,
        v_retry.event_id, v_retry.change_seq, v_retry.patient_uid, v_retry.document_uid, v_retry.record_version,
        v_retry.base_version, v_retry.operation_type, v_change, nps.payload_digest(v_change))) IS DISTINCT FROM 'Conflict'
    THEN RAISE EXCEPTION 'Replay conflict'; END IF;
    IF NOT EXISTS (SELECT 1 FROM nps.sync_conflict_log WHERE reason_code = 'IDEMPOTENCY_KEY_REUSED')
    THEN RAISE EXCEPTION 'Replay conflict audit'; END IF;

    IF nps.finish_sync_event('TEST-F01', v_retry.event_id, v_retry.claim_token, v_received.receipt_uid::TEXT)
        IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'Acknowledgement failed'; END IF;
    IF (SELECT last_acknowledged_change_seq FROM nps.sync_checkpoint WHERE source_facility_id = 'TEST-F01')
          IS DISTINCT FROM v_retry.change_seq
    THEN RAISE EXCEPTION 'Acknowledgement did not advance to the accepted head'; END IF;

    SELECT * INTO v_two FROM nps.claim_sync_event('TEST-F01');
    IF v_two.document_uid IS DISTINCT FROM v_doc2 OR v_two.base_version IS DISTINCT FROM 1
    THEN RAISE EXCEPTION 'Next release or base version'; END IF;
    IF nps.finish_sync_event('TEST-F01', v_two.event_id, v_two.claim_token, NULL, 'NEEDS_REVIEW', TRUE)
        IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'Permanent failure recording'; END IF;
    IF EXISTS (SELECT 1 FROM nps.claim_sync_event('TEST-F01'))
    THEN RAISE EXCEPTION 'Permanent failure handling'; END IF;
    IF nps.requeue_failed_event('TEST-F01', v_two.event_id) IS DISTINCT FROM TRUE
    THEN RAISE EXCEPTION 'Operator requeue'; END IF;

    SELECT * INTO v_two FROM nps.claim_sync_event('TEST-F01');
    UPDATE nps.sync_outbox_event SET lease_until = clock_timestamp() - interval '1 second'
    WHERE event_id = v_two.event_id;
    SELECT * INTO v_retry FROM nps.claim_sync_event('TEST-F01');
    IF v_retry.event_id IS DISTINCT FROM v_two.event_id OR v_retry.attempt_count IS DISTINCT FROM 3
       OR NOT EXISTS (SELECT 1 FROM nps.sync_attempt WHERE claim_token = v_two.claim_token AND outcome = 'Expired')
    THEN RAISE EXCEPTION 'Worker crash recovery'; END IF;
    SELECT * INTO v_received FROM nps.receive_sync_event(v_retry.source_facility_id, v_retry.source_system,
        v_retry.event_id, v_retry.change_seq, v_retry.patient_uid, v_retry.document_uid, v_retry.record_version,
        v_retry.base_version, v_retry.operation_type, v_retry.payload, v_retry.payload_sha256);
    IF v_received.outcome IS DISTINCT FROM 'Accepted'
       OR nps.finish_sync_event('TEST-F01', v_retry.event_id, v_retry.claim_token, v_received.receipt_uid::TEXT)
          IS DISTINCT FROM TRUE
    THEN RAISE EXCEPTION 'Next release delivery'; END IF;
    IF nps.get_patient_summary(v_patient) #>> '{synchronisationStatus,state}' IS DISTINCT FROM 'Acknowledged'
       OR NOT EXISTS (SELECT 1 FROM nps.received_current_summary
                     WHERE record_version = 2 AND receipt_uid = v_received.receipt_uid
                       AND (payload #>> '{documentAndProvenance,nps0116ReceivedDateTime}')::TIMESTAMPTZ = v_received.received_at)
    THEN RAISE EXCEPTION 'Read model or receiver-assigned receipt time'; END IF;

    PERFORM nps.invalidate_released_summary(v_doc2);
    PERFORM nps.invalidate_released_summary(v_doc2);
    SELECT * INTO v_delete FROM nps.claim_sync_event('TEST-F01');
    IF v_delete.operation_type IS DISTINCT FROM 'INVALIDATE'
       OR v_delete.payload IS DISTINCT FROM '{"documentId":"SYNTHETIC-DOC-1-V2"}'::JSONB
       OR nps.get_patient_summary(v_patient) IS NOT NULL
    THEN RAISE EXCEPTION 'Invalidation tombstone'; END IF;
    SELECT * INTO v_received FROM nps.receive_sync_event(v_delete.source_facility_id, v_delete.source_system,
        v_delete.event_id, v_delete.change_seq, v_delete.patient_uid, v_delete.document_uid, v_delete.record_version,
        v_delete.base_version, v_delete.operation_type, v_delete.payload, v_delete.payload_sha256);
    IF v_received.outcome IS DISTINCT FROM 'Accepted'
       OR nps.finish_sync_event('TEST-F01', v_delete.event_id, v_delete.claim_token, v_received.receipt_uid::TEXT)
          IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'Tombstone delivery'; END IF;
    IF EXISTS (SELECT 1 FROM nps.claim_sync_event('TEST-F01'))
       OR EXISTS (SELECT 1 FROM nps.received_current_summary WHERE source_patient_uid = v_patient)
       OR EXISTS (SELECT 1 FROM nps.validation_issues WHERE issue_code LIKE 'CHECKPOINT_%')
    THEN RAISE EXCEPTION 'Tombstone delivery or checkpoint mismatch'; END IF;
END;
$$;

DO $$
DECLARE
    v_patient UUID := '00000000-0000-4000-8000-000000000001';
    v_document UUID := '00000000-0000-4000-8000-000000000041';
    v_current_checkpoint BIGINT;
    v_version INTEGER;
    v_event nps.sync_outbox_event%ROWTYPE;
BEGIN
    SELECT last_acknowledged_change_seq INTO v_current_checkpoint FROM nps.sync_checkpoint
    WHERE source_facility_id = 'TEST-F01';
    FOR v_version IN 3..4 LOOP
        INSERT INTO nps.summary_document (document_uid, patient_uid, document_id, document_version,
            version_number, shared_patient_id, source_facility_id, source_emr, generated_date_time,
            document_status, author_assembler, generation_method, language_choice, confidentiality)
        VALUES (v_document, v_patient, 'SYNTHETIC-DOC-1-V' || v_version, v_version::TEXT,
            v_version, 'TEST-MPI-1', 'TEST-F01', 'TEST-EMR', clock_timestamp(), 'Current',
            'Synthetic test builder', 'Automated', 'English', 'Normal');
        PERFORM nps.publish_patient_summary(v_document,
            (SELECT revision FROM nps.patient_revision WHERE patient_uid = v_patient), TRUE);
        IF v_version = 3 THEN
            PERFORM nps.invalidate_released_summary(v_document);
            IF NOT EXISTS (SELECT 1 FROM nps.sync_outbox_event
                           WHERE document_uid = v_document AND transfer_status = 'Cancelled' AND attempt_count = 0)
               OR EXISTS (SELECT 1 FROM nps.claim_sync_event('TEST-F01'))
               OR (SELECT last_acknowledged_change_seq FROM nps.sync_checkpoint WHERE source_facility_id = 'TEST-F01')
                  IS DISTINCT FROM v_current_checkpoint
            THEN RAISE EXCEPTION 'Unattempted release cancellation'; END IF;
            v_document := '00000000-0000-4000-8000-000000000042';
        END IF;
    END LOOP;
    SELECT * INTO v_event FROM nps.claim_sync_event('TEST-F01');
    IF v_event.document_uid IS DISTINCT FROM v_document OR v_event.base_version IS DISTINCT FROM 2
    THEN RAISE EXCEPTION 'Cancelled release affected the next transferable version'; END IF;
END;
$$;

SET LOCAL ROLE nps_sync_sender;
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM nps.claim_authorised_sync_event('TEST-F01'))
       OR has_table_privilege(current_user, 'nps.sync_outbox_event', 'SELECT')
       OR has_function_privilege(current_user, 'nps.claim_sync_event(varchar)', 'EXECUTE')
    THEN RAISE EXCEPTION 'Sender role scope bypass'; END IF;
END;
$$;
ROLLBACK;
