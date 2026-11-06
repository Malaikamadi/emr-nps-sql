-- =============================================================================
-- PROJECT: Sierra Leone EMR National Patient Summary (NPS)
-- FILE:    sql/002_create_tables.sql
-- TARGET:  PostgreSQL 17+
--
-- PURPOSE:
--   Create all relational tables in the `nps` schema covering:
--     - Patient demographics, issuer-qualified identifiers, and emergency contacts (NPS-02)
--     - Summary documents and provenance (NPS-01)
--     - Clinical encounters and section completeness (NPS-03, NPS-04)
--     - Common clinical entry metadata (NPS-04)
--     - All clinical sections (NPS-05 through NPS-20)
--     - Offline-first synchronisation outbox, checkpoints, inbox receipts, and conflicts
--     - Security and patient-access audit trail
-- =============================================================================

BEGIN;

-- =============================================================================
-- 1. PATIENT DEMOGRAPHICS & CORE IDENTITY (NPS-02, NPS-01-03)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.patient (
    -- Proposed internal NPS surrogate identifier (not an assumed native EMR key)
    patient_uid                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    -- NPS-01-03 (M): Shared client identifier (MPI/shared ID; or facility:mrn if MPI pending; national ID not compulsory)
    mpi_patient_id             VARCHAR(128),
    -- NPS-02-02 (M): Primary source patient identifier & issuing facility
    primary_source_patient_id  VARCHAR(128) NOT NULL,
    primary_source_facility_id VARCHAR(128) NOT NULL,
    primary_source_system      VARCHAR(150) NOT NULL,
    -- NPS-02-01 (M): Name as recorded in EMR (Do not require surname)
    patient_name               TEXT         NOT NULL,
    -- NPS-02-04 (K): Recorded sex (Male; Female; Other; Unknown)
    sex                        VARCHAR(16),
    -- NPS-02-05 (K): Birth date if known (Full or partial date: YYYY, YYYY-MM, YYYY-MM-DD; do not invent month/day)
    date_of_birth_raw          VARCHAR(32),
    date_of_birth_exact        DATE,
    date_of_birth_precision    VARCHAR(16),
    -- NPS-02-06 (K): Age at assessment if DOB unknown (Days; Months; Years)
    age_at_assessment_value    NUMERIC(6,2),
    age_at_assessment_unit     VARCHAR(16),
    -- NPS-02-07 (K): Date age was recorded (Needed for interpreting age)
    date_of_age_assessment     DATE,
    -- NPS-02-08 (K): Whether DOB was estimated (Yes; No; Unknown; only if DOB supplied)
    estimated_birth_date       VARCHAR(16),
    -- NPS-02-09 (K): Whether person is alive (Alive; Deceased; Unknown; do not infer)
    vital_status               VARCHAR(16),
    -- NPS-02-10 (O): Patient contact number (Phone number; Not available; access restricted)
    phone_number               VARCHAR(64),
    -- NPS-02-11 (K): District of residence (Approved district list)
    district                   VARCHAR(100),
    -- NPS-02-12 (O): Chiefdom of residence (Approved chiefdom list)
    chiefdom                   VARCHAR(100),
    -- NPS-02-13 (O): Town or community (Free text; do not require street address)
    locality                   TEXT,
    -- NPS-02-15 (O): Whether contact may be used (Permitted; Restricted; Unknown; do not assume permission)
    contact_permission         VARCHAR(16),
    -- Record lifecycle & offline synchronisation metadata
    record_status              VARCHAR(32)  NOT NULL DEFAULT 'Active',
    merged_into_patient_uid    UUID,
    change_seq                 BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                 TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                 TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.patient                            IS 'NPS-02 (Core): Patient demographics, residence, contact permission, and primary source identity.';
COMMENT ON COLUMN nps.patient.patient_uid                IS 'Proposed internal NPS surrogate UUID (used by nps.get_patient_summary).';
COMMENT ON COLUMN nps.patient.mpi_patient_id             IS 'NPS-01-03 (M): Shared client identifier (MPI/shared ID when assigned).';
COMMENT ON COLUMN nps.patient.primary_source_patient_id  IS 'NPS-02-02 (M): Primary patient ID (MRN) used in the originating facility.';
COMMENT ON COLUMN nps.patient.primary_source_facility_id IS 'NPS-02-02 (M): Originating facility identifier that issued primary_source_patient_id.';
COMMENT ON COLUMN nps.patient.patient_name               IS 'NPS-02-01 (M): Patient name as recorded in EMR. Do not require surname.';
COMMENT ON COLUMN nps.patient.sex                        IS 'NPS-02-04 (K): Recorded sex (Male; Female; Other; Unknown). Preserve source value.';
COMMENT ON COLUMN nps.patient.date_of_birth_raw          IS 'NPS-02-05 (K): Birth date if known (full or partial date). Do not invent missing month/day.';
COMMENT ON COLUMN nps.patient.age_at_assessment_value    IS 'NPS-02-06 (K): Age numeric value if DOB unknown.';
COMMENT ON COLUMN nps.patient.age_at_assessment_unit     IS 'NPS-02-06 (K): Age unit (Days; Months; Years) if DOB unknown.';
COMMENT ON COLUMN nps.patient.date_of_age_assessment     IS 'NPS-02-07 (K): Date age was recorded (needed for interpreting age).';
COMMENT ON COLUMN nps.patient.estimated_birth_date       IS 'NPS-02-08 (K): Whether DOB was estimated (Yes; No; Unknown). Only if DOB supplied.';
COMMENT ON COLUMN nps.patient.vital_status               IS 'NPS-02-09 (K): Whether person is alive (Alive; Deceased; Unknown). Do not infer.';
COMMENT ON COLUMN nps.patient.phone_number               IS 'NPS-02-10 (O): Patient contact number or Not available. Access restricted.';
COMMENT ON COLUMN nps.patient.district                   IS 'NPS-02-11 (K): District of residence from approved district list.';
COMMENT ON COLUMN nps.patient.chiefdom                   IS 'NPS-02-12 (O): Chiefdom of residence from approved chiefdom list.';
COMMENT ON COLUMN nps.patient.locality                   IS 'NPS-02-13 (O): Town or community. Do not require street address.';
COMMENT ON COLUMN nps.patient.contact_permission         IS 'NPS-02-15 (O): Whether contact may be used (Permitted; Restricted; Unknown). Do not assume permission.';

-- =============================================================================
-- 2. PATIENT IDENTIFIERS (1..* Issuer-Qualified IDs: NPS-02-02, NPS-02-03)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.patient_identifier (
    identifier_uid       UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid          UUID         NOT NULL,
    -- 'NPS-02-02' (source facility MRN) or 'NPS-02-03' (other identifier: immunization ID, national ID, etc.)
    nps_element_id       VARCHAR(16)  NOT NULL,
    identifier_type      VARCHAR(64)  NOT NULL,
    identifier_value     VARCHAR(128) NOT NULL,
    issuing_facility_id  VARCHAR(128) NOT NULL,
    issuing_system       VARCHAR(150) NOT NULL,
    is_primary_source_id BOOLEAN      NOT NULL DEFAULT FALSE,
    identifier_status    VARCHAR(32)  NOT NULL DEFAULT 'Active',
    recorded_at          TIMESTAMPTZ,
    change_seq           BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.patient_identifier                     IS 'NPS-02-02 & NPS-02-03: One-to-many issuer-qualified patient identifiers. National ID is optional and never mandatory.';
COMMENT ON COLUMN nps.patient_identifier.nps_element_id      IS 'Traceability to NPS-02-02 (Source patient identifier) or NPS-02-03 (Other patient identifiers).';
COMMENT ON COLUMN nps.patient_identifier.identifier_value    IS 'Identifier string qualified by issuing_facility_id and issuing_system.';
COMMENT ON COLUMN nps.patient_identifier.issuing_facility_id IS 'Facility or authority that issued this identifier.';

-- =============================================================================
-- 3. PATIENT EMERGENCY CONTACTS (0..* Contacts: NPS-02-14, NPS-02-15)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.patient_contact_person (
    contact_uid                UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid                UUID         NOT NULL,
    -- NPS-02-14 (O): Named contact and relationship (Name; Relationship; Phone; not automatically legal representative)
    contact_name               TEXT         NOT NULL,
    relationship               VARCHAR(100),
    phone_number               VARCHAR(64),
    raw_contact_text           TEXT,
    -- NPS-02-15 (O): Contact permission for this emergency contact
    contact_permission         VARCHAR(16),
    is_legal_representative    BOOLEAN      NOT NULL DEFAULT FALSE,
    record_status              VARCHAR(32)  NOT NULL DEFAULT 'Active',
    change_seq                 BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                 TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                 TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.patient_contact_person            IS 'NPS-02-14 & NPS-02-15: Named emergency contacts and relationships. Not automatically legal representative.';
COMMENT ON COLUMN nps.patient_contact_person.contact_name IS 'NPS-02-14 (O): Named contact person.';
COMMENT ON COLUMN nps.patient_contact_person.relationship IS 'NPS-02-14 (O): Relationship to patient.';
COMMENT ON COLUMN nps.patient_contact_person.phone_number IS 'NPS-02-14 (O): Emergency contact phone number.';

-- =============================================================================
-- 4. SUMMARY DOCUMENT & PROVENANCE (Block 01: NPS-01-01 to NPS-01-17)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.summary_document (
    document_uid            UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid             UUID         NOT NULL,
    -- NPS-01-01 (M): Unique NPS document identifier (One per summary version)
    document_id             VARCHAR(128) NOT NULL UNIQUE,
    -- NPS-01-02 (M): Version of this summary ("1, 2, 3…"; retain earlier versions)
    document_version        VARCHAR(32)  NOT NULL,
    version_number          INTEGER      NOT NULL,
    -- NPS-01-03 (M): Shared client identifier (MPI/shared ID; issuer-qualified facility ID if pending)
    shared_patient_id       TEXT         NOT NULL,
    -- NPS-01-04 (M): Facility where source data originated (Health Facility Registry ID; approved temporary ID)
    source_facility_id      VARCHAR(128) NOT NULL,
    -- NPS-01-05 (M): System providing information (Approved EMR system list)
    source_emr              VARCHAR(150) NOT NULL,
    -- NPS-01-06 (M): When NPS was assembled (Recorded timestamp with timezone; not the clinical event date)
    generated_date_time     TIMESTAMPTZ  NOT NULL,
    -- NPS-01-07 (M): Status of summary (Current; Superseded; Entered in error; never overwrite previous version)
    document_status         VARCHAR(32)  NOT NULL,
    -- NPS-01-08 (M): Person, organization or software that created NPS (Do not invent clinician sign-off)
    author_assembler        TEXT         NOT NULL,
    author_type             VARCHAR(32)  NOT NULL DEFAULT 'Software',
    -- NPS-01-09 (M): How summary was created (Automated; Clinician-reviewed; Manual; different from attestation)
    generation_method       VARCHAR(32)  NOT NULL,
    -- NPS-01-10 (M): Language of summary (English; Other (specify))
    language_choice         VARCHAR(32)  NOT NULL,
    language_other          VARCHAR(100),
    -- NPS-01-11 (M): Overall sharing restriction (Normal; Restricted; Highly restricted)
    confidentiality         VARCHAR(32)  NOT NULL,
    -- NPS-01-12 (K): Period covered by source records (Start date; End date)
    clinical_period_start   DATE,
    clinical_period_end     DATE,
    -- NPS-01-13 (O): Person confirming summary accuracy (Provider ID; Name; only when actually attested)
    attester                TEXT,
    -- NPS-01-14 (O): When summary was confirmed (Recorded timestamp; do not infer from extraction)
    attestation_date_time   TIMESTAMPTZ,
    -- NPS-01-15 (O): Organization responsible for document (Organization ID and name)
    custodian               TEXT,
    -- NPS-01-16 (M): When SHR received the summary (System recorded timestamp)
    received_date_time      TIMESTAMPTZ,
    -- NPS-01-17 (K): Reference to originating record (Source document or encounter ID)
    source_record_reference VARCHAR(128),
    -- Version chain & sync tracking
    supersedes_document_uid UUID,
    change_seq              BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.summary_document                         IS 'NPS-01 (Core): Document & provenance header for each immutable patient summary version.';
COMMENT ON COLUMN nps.summary_document.document_id             IS 'NPS-01-01 (M): Unique NPS document identifier. One per summary version.';
COMMENT ON COLUMN nps.summary_document.document_version        IS 'NPS-01-02 (M): Version of this summary (1, 2, 3…). Retain earlier versions.';
COMMENT ON COLUMN nps.summary_document.shared_patient_id       IS 'NPS-01-03 (M): Shared client identifier (MPI/shared ID; issuer-qualified facility ID if pending).';
COMMENT ON COLUMN nps.summary_document.source_facility_id      IS 'NPS-01-04 (M): Facility where source data originated.';
COMMENT ON COLUMN nps.summary_document.source_emr              IS 'NPS-01-05 (M): System providing information.';
COMMENT ON COLUMN nps.summary_document.generated_date_time     IS 'NPS-01-06 (M): When NPS was assembled (with timezone). Not the clinical event date.';
COMMENT ON COLUMN nps.summary_document.document_status         IS 'NPS-01-07 (M): Status of summary (Current; Superseded; Entered in error). Never overwrite previous version.';
COMMENT ON COLUMN nps.summary_document.author_assembler        IS 'NPS-01-08 (M): Person, organization or software that created NPS. Do not invent clinician sign-off.';
COMMENT ON COLUMN nps.summary_document.generation_method       IS 'NPS-01-09 (M): How summary was created (Automated; Clinician-reviewed; Manual).';
COMMENT ON COLUMN nps.summary_document.language_choice         IS 'NPS-01-10 (M): Language of summary (English; Other (specify)).';
COMMENT ON COLUMN nps.summary_document.confidentiality         IS 'NPS-01-11 (M): Overall sharing restriction (Normal; Restricted; Highly restricted).';
COMMENT ON COLUMN nps.summary_document.clinical_period_start   IS 'NPS-01-12 (K): Start date of period covered by source records.';
COMMENT ON COLUMN nps.summary_document.clinical_period_end     IS 'NPS-01-12 (K): End date of period covered by source records.';
COMMENT ON COLUMN nps.summary_document.attester                IS 'NPS-01-13 (O): Person confirming summary accuracy. Only when actually attested.';
COMMENT ON COLUMN nps.summary_document.attestation_date_time   IS 'NPS-01-14 (O): When summary was confirmed. Do not infer from extraction.';
COMMENT ON COLUMN nps.summary_document.custodian               IS 'NPS-01-15 (O): Organization responsible for document.';
COMMENT ON COLUMN nps.summary_document.received_date_time      IS 'NPS-01-16 (M): When SHR received the summary.';
COMMENT ON COLUMN nps.summary_document.source_record_reference IS 'NPS-01-17 (K): Reference to originating source document or encounter ID.';

-- =============================================================================
-- 5. CLINICAL ENCOUNTER PROVENANCE (Supports NPS-04-08 & NPS-01-17)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.clinical_encounter (
    encounter_uid        UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid          UUID         NOT NULL,
    source_encounter_id  VARCHAR(128) NOT NULL,
    source_facility_id   VARCHAR(128) NOT NULL,
    source_system        VARCHAR(150) NOT NULL,
    encounter_type       VARCHAR(64),
    encounter_start_raw  VARCHAR(64),
    encounter_start_time TIMESTAMPTZ,
    encounter_end_time   TIMESTAMPTZ,
    attending_provider_id VARCHAR(128),
    record_status        VARCHAR(32)  NOT NULL DEFAULT 'Active',
    change_seq           BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE nps.clinical_encounter IS
    'Encounter/consultation provenance table supporting NPS-04-08 (Source encounter) and NPS-01-17 (Source record reference).';

-- =============================================================================
-- 6. SECTION COMPLETENESS (Block 03: NPS-03-01 to NPS-03-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.section_completeness (
    section_completeness_uid       UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    document_uid                   UUID         NOT NULL,
    patient_uid                    UUID         NOT NULL,
    -- NPS-03-01 (M): Clinical section being reported (One status per block)
    nps_block_code                 VARCHAR(16)  NOT NULL,
    nps_block_name                 VARCHAR(100) NOT NULL,
    -- NPS-03-02 (M): Whether clinical information is available
    -- (Entries present; None known; Unknown; Not asked; Not applicable; Withheld)
    section_information_status     VARCHAR(32)  NOT NULL,
    absence_evidence_ref TEXT,
    -- NPS-03-03 (M): Whether source section was successfully obtained
    -- (Complete; Partial; Unsupported; Failed)
    extraction_status              VARCHAR(32)  NOT NULL,
    -- NPS-03-04 (K): When section was clinically assessed
    last_assessed_date             DATE,
    -- NPS-03-05 (K): Why data are missing (Not recorded; Not assessed; Source unavailable; Restricted; Other)
    reason_information_unavailable VARCHAR(32),
    reason_unavailable_other       TEXT,
    -- NPS-03-06 (K): Section-specific sharing control (Normal; Restricted; Withheld)
    section_access_restriction     VARCHAR(32)  NOT NULL DEFAULT 'Normal',
    change_seq                     BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                     TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.section_completeness                                IS 'NPS-03 (Core): Section completeness, extraction status, and access restriction per clinical block.';
COMMENT ON COLUMN nps.section_completeness.nps_block_name                 IS 'NPS-03-01 (M): Clinical section being reported.';
COMMENT ON COLUMN nps.section_completeness.section_information_status     IS 'NPS-03-02 (M): Entries present; None known; Unknown; Not asked; Not applicable; Withheld.';
COMMENT ON COLUMN nps.section_completeness.extraction_status              IS 'NPS-03-03 (M): Complete; Partial; Unsupported; Failed. Failed must never be interpreted as None known.';
COMMENT ON COLUMN nps.section_completeness.last_assessed_date             IS 'NPS-03-04 (K): Date when section was clinically assessed.';
COMMENT ON COLUMN nps.section_completeness.reason_information_unavailable IS 'NPS-03-05 (K): Not recorded; Not assessed; Source unavailable; Restricted; Other.';
COMMENT ON COLUMN nps.section_completeness.section_access_restriction     IS 'NPS-03-06 (K): Normal; Restricted; Withheld.';

-- =============================================================================
-- 7. COMMON CLINICAL ENTRY METADATA (Block 04: NPS-04-01 to NPS-04-10)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.clinical_entry (
    entry_uid                     UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid                   UUID         NOT NULL,
    document_uid                  UUID,
    nps_block_code                VARCHAR(16)  NOT NULL,
    -- NPS-04-01 (M): Identifier of individual clinical entry (Source record ID or governed surrogate)
    clinical_entry_id             VARCHAR(128) NOT NULL,
    -- NPS-04-02 (M): Facility recording clinical entry (May differ from NPS author)
    source_facility_id            VARCHAR(128) NOT NULL,
    -- NPS-04-03 (M): EMR containing clinical entry (Retain provenance)
    source_system                 VARCHAR(150) NOT NULL,
    -- NPS-04-04 (K): When source documented the entry (Different from event date)
    date_recorded                 TIMESTAMPTZ,
    -- NPS-04-05 (K): When event occurred (Full/partial date or date/time; Unknown; retain date precision)
    clinical_event_date_raw       VARCHAR(64),
    clinical_event_timestamp      TIMESTAMPTZ,
    clinical_event_date_precision VARCHAR(32),
    -- NPS-04-06 (M): Unchanged source clinical wording (Preserve original meaning)
    original_recorded_description TEXT         NOT NULL,
    -- NPS-04-07 (K): Provider who recorded entry (Provider ID; Unknown)
    source_provider_id            VARCHAR(128),
    -- NPS-04-08 (K): Linked consultation/visit (Encounter ID)
    source_encounter_id           VARCHAR(128),
    encounter_uid                 UUID,
    -- NPS-04-09 (K): How reliably entry is established (Confirmed; Suspected; Unconfirmed; Unknown)
    verification                  VARCHAR(32),
    -- NPS-04-10 (K): Code recorded by source system (Local code; ICD; SNOMED CT; other; do not invent mapping)
    original_clinical_code        VARCHAR(128),
    original_code_system          VARCHAR(64),
    -- Record lifecycle state (supports corrections and soft invalidation without overwriting history)
    record_lifecycle_status       VARCHAR(32)  NOT NULL DEFAULT 'Active',
    replaces_entry_uid            UUID,
    invalidation_reason           TEXT,
    change_seq                    BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                    TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.clinical_entry                               IS 'NPS-04 (Core): Common clinical entry metadata shared by all clinical records across blocks NPS-05 to NPS-20.';
COMMENT ON COLUMN nps.clinical_entry.clinical_entry_id             IS 'NPS-04-01 (M): Identifier of individual clinical entry (source record ID or governed surrogate).';
COMMENT ON COLUMN nps.clinical_entry.source_facility_id            IS 'NPS-04-02 (M): Facility recording clinical entry.';
COMMENT ON COLUMN nps.clinical_entry.source_system                 IS 'NPS-04-03 (M): EMR containing clinical entry.';
COMMENT ON COLUMN nps.clinical_entry.date_recorded                 IS 'NPS-04-04 (K): When source documented the entry (different from event date).';
COMMENT ON COLUMN nps.clinical_entry.clinical_event_date_raw       IS 'NPS-04-05 (K): When event occurred (full/partial date or Unknown; retain precision).';
COMMENT ON COLUMN nps.clinical_entry.original_recorded_description IS 'NPS-04-06 (M): Unchanged source clinical wording.';
COMMENT ON COLUMN nps.clinical_entry.source_provider_id            IS 'NPS-04-07 (K): Provider who recorded entry (Provider ID; Unknown).';
COMMENT ON COLUMN nps.clinical_entry.source_encounter_id           IS 'NPS-04-08 (K): Linked consultation/visit (Encounter ID).';
COMMENT ON COLUMN nps.clinical_entry.verification                  IS 'NPS-04-09 (K): Confirmed; Suspected; Unconfirmed; Unknown.';
COMMENT ON COLUMN nps.clinical_entry.original_clinical_code        IS 'NPS-04-10 (K): Code recorded by source system. Do not invent mapping.';

-- =============================================================================
-- 8. BLOCK 05: PROBLEMS & DIAGNOSES (NPS-05-01 to NPS-05-08)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.problem_diagnosis (
    entry_uid              UUID         PRIMARY KEY,
    patient_uid            UUID         NOT NULL,
    -- NPS-05-01 (M): Clinically relevant condition (Approved diagnosis list; Free text if uncoded)
    problem_diagnosis_code VARCHAR(128),
    problem_diagnosis_text TEXT,
    -- NPS-05-02 (M): Whether condition is ongoing (Active; Resolved; Inactive; Unknown; do not assume resolved)
    problem_status         VARCHAR(32)  NOT NULL,
    -- NPS-05-03 (M): Certainty of diagnosis (Confirmed; Suspected; Unconfirmed; Unknown; preserve provisional diagnosis)
    diagnosis_certainty    VARCHAR(32)  NOT NULL,
    -- NPS-05-04 (K): When condition began (Recorded full/partial date; do not estimate)
    onset_date_raw         VARCHAR(32),
    onset_date_exact       DATE,
    -- NPS-05-05 (K): When condition ended (Recorded date; only if known)
    resolution_date_raw    VARCHAR(32),
    resolution_date_exact  DATE,
    -- NPS-05-06 (K): Documented severity (Mild; Moderate; Severe; Unknown; Other; no inferred grading)
    severity               VARCHAR(32),
    severity_other         TEXT,
    -- NPS-05-07 (K): Evidence supporting diagnosis (Clinical; Laboratory; Imaging; Patient-reported; Unknown)
    diagnosis_basis        VARCHAR(32),
    -- NPS-05-08 (O): Brief relevant treatment/follow-up context (Avoid copying full note)
    management_note        TEXT,
    change_seq             BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.problem_diagnosis                        IS 'NPS-05 (Required): Problems & diagnoses section.';
COMMENT ON COLUMN nps.problem_diagnosis.problem_diagnosis_text IS 'NPS-05-01 (M): Clinically relevant condition (approved diagnosis list or free text).';
COMMENT ON COLUMN nps.problem_diagnosis.problem_status         IS 'NPS-05-02 (M): Active; Resolved; Inactive; Unknown. Do not assume resolved.';
COMMENT ON COLUMN nps.problem_diagnosis.diagnosis_certainty    IS 'NPS-05-03 (M): Confirmed; Suspected; Unconfirmed; Unknown.';
COMMENT ON COLUMN nps.problem_diagnosis.onset_date_raw         IS 'NPS-05-04 (K): Onset date (full/partial). Do not estimate.';
COMMENT ON COLUMN nps.problem_diagnosis.resolution_date_raw    IS 'NPS-05-05 (K): Resolution date if known.';
COMMENT ON COLUMN nps.problem_diagnosis.severity               IS 'NPS-05-06 (K): Mild; Moderate; Severe; Unknown; Other. No inferred grading.';
COMMENT ON COLUMN nps.problem_diagnosis.diagnosis_basis        IS 'NPS-05-07 (K): Clinical; Laboratory; Imaging; Patient-reported; Unknown.';
COMMENT ON COLUMN nps.problem_diagnosis.management_note        IS 'NPS-05-08 (O): Brief relevant treatment/follow-up context.';

-- =============================================================================
-- 9. BLOCK 06: ALLERGIES & INTOLERANCES (NPS-06-01 to NPS-06-08)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.allergy_intolerance (
    entry_uid            UUID         PRIMARY KEY,
    patient_uid          UUID         NOT NULL,
    -- NPS-06-01 (M): Substance or agent involved (Medicine; Food; Environmental; Other; Unknown agent)
    allergen_code        VARCHAR(128),
    allergen_text        TEXT,
    -- NPS-06-02 (M): Whether allergy is current (Active; Inactive; Resolved; Unknown; not recorded != none known)
    allergy_status       VARCHAR(32)  NOT NULL,
    -- NPS-06-03 (M): Certainty of allergy record (Confirmed; Unconfirmed; Refuted; Unknown)
    verification_status  VARCHAR(32)  NOT NULL,
    -- NPS-06-04 (K): Type of agent (Medication; Food; Environment; Other)
    allergy_category     VARCHAR(32),
    -- NPS-06-05 (K): Clinical reaction experienced (Rash; Breathing difficulty; Other (specify); do not infer from adverse event)
    reaction_code        VARCHAR(128),
    reaction_text        TEXT,
    -- NPS-06-06 (K): Severity of observed reaction (Mild; Moderate; Severe; Unknown; different from future risk)
    reaction_severity    VARCHAR(32),
    -- NPS-06-07 (K): Potential seriousness of future exposure (Low; High; Unable to assess)
    criticality          VARCHAR(32),
    -- NPS-06-08 (K): Date allergy first recorded
    first_noted_date_raw VARCHAR(32),
    first_noted_date     DATE,
    change_seq           BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at           TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.allergy_intolerance                      IS 'NPS-06 (Required): Allergies & intolerances section.';
COMMENT ON COLUMN nps.allergy_intolerance.allergen_text        IS 'NPS-06-01 (M): Substance or agent involved.';
COMMENT ON COLUMN nps.allergy_intolerance.allergy_status       IS 'NPS-06-02 (M): Active; Inactive; Resolved; Unknown.';
COMMENT ON COLUMN nps.allergy_intolerance.verification_status  IS 'NPS-06-03 (M): Confirmed; Unconfirmed; Refuted; Unknown.';
COMMENT ON COLUMN nps.allergy_intolerance.allergy_category     IS 'NPS-06-04 (K): Medication; Food; Environment; Other.';
COMMENT ON COLUMN nps.allergy_intolerance.reaction_text        IS 'NPS-06-05 (K): Clinical reaction experienced. Do not infer from adverse event.';
COMMENT ON COLUMN nps.allergy_intolerance.reaction_severity    IS 'NPS-06-06 (K): Mild; Moderate; Severe; Unknown.';
COMMENT ON COLUMN nps.allergy_intolerance.criticality          IS 'NPS-06-07 (K): Low; High; Unable to assess.';
COMMENT ON COLUMN nps.allergy_intolerance.first_noted_date_raw IS 'NPS-06-08 (K): Date allergy first recorded.';

-- =============================================================================
-- 10. BLOCK 07: MEDICATION SUMMARY (NPS-07-01 to NPS-07-11)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.medication_summary (
    entry_uid           UUID          PRIMARY KEY,
    patient_uid         UUID          NOT NULL,
    -- NPS-07-01 (M): Medicine name (National formulary/generic list; Free text)
    medicine_code       VARCHAR(128),
    medicine_name       TEXT,
    -- NPS-07-02 (M): Current medication-use status (Active; Completed; Stopped; Unknown; do not infer active from prescription)
    medication_status   VARCHAR(32)   NOT NULL,
    -- NPS-07-03 (M): Source of medication information (Prescribed; Dispensed; Administered; Patient-reported; Unknown)
    evidence_of_use     VARCHAR(32)   NOT NULL,
    -- NPS-07-04 (K): Product strength (e.g., 500 mg tablet; separate from dose)
    strength            TEXT,
    -- NPS-07-05 (K): Amount per administration (e.g., 1 tablet; 5 mL; keep complex instructions verbatim)
    dose_value          NUMERIC(12,4),
    dose_unit           VARCHAR(64),
    dose_text           TEXT,
    -- NPS-07-06 (K): How medicine is taken (Oral; Intravenous; Intramuscular; Topical; Other)
    route               VARCHAR(32),
    route_other         TEXT,
    -- NPS-07-07 (K): How often medicine is taken (Once daily; Twice daily; As needed; Other; do not infer)
    frequency           TEXT,
    -- NPS-07-08 (K): Medication start date
    start_date_raw      VARCHAR(32),
    start_date          DATE,
    -- NPS-07-09 (K): Medication end date
    end_date_raw        VARCHAR(32),
    end_date            DATE,
    -- NPS-07-10 (K): Condition or indication (Diagnosis; Free text)
    reason_for_use_code VARCHAR(128),
    reason_for_use_text TEXT,
    -- NPS-07-11 (K): Provider responsible for prescription (Provider ID)
    prescriber_id       VARCHAR(128),
    change_seq          BIGINT        NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.medication_summary                     IS 'NPS-07 (Required): Medication summary section.';
COMMENT ON COLUMN nps.medication_summary.medicine_name       IS 'NPS-07-01 (M): Medicine name.';
COMMENT ON COLUMN nps.medication_summary.medication_status   IS 'NPS-07-02 (M): Active; Completed; Stopped; Unknown. Do not infer active from prescription.';
COMMENT ON COLUMN nps.medication_summary.evidence_of_use     IS 'NPS-07-03 (M): Prescribed; Dispensed; Administered; Patient-reported; Unknown.';
COMMENT ON COLUMN nps.medication_summary.strength            IS 'NPS-07-04 (K): Product strength (separate from dose).';
COMMENT ON COLUMN nps.medication_summary.dose_text           IS 'NPS-07-05 (K): Amount per administration (keep complex instructions verbatim).';
COMMENT ON COLUMN nps.medication_summary.route               IS 'NPS-07-06 (K): Oral; Intravenous; Intramuscular; Topical; Other.';
COMMENT ON COLUMN nps.medication_summary.frequency           IS 'NPS-07-07 (K): How often medicine is taken. Do not infer.';
COMMENT ON COLUMN nps.medication_summary.start_date_raw      IS 'NPS-07-08 (K): Medication start date.';
COMMENT ON COLUMN nps.medication_summary.end_date_raw        IS 'NPS-07-09 (K): Medication end date.';
COMMENT ON COLUMN nps.medication_summary.reason_for_use_text IS 'NPS-07-10 (K): Condition or indication.';
COMMENT ON COLUMN nps.medication_summary.prescriber_id       IS 'NPS-07-11 (K): Provider responsible for prescription.';

-- =============================================================================
-- 11. BLOCK 08: IMMUNIZATIONS (NPS-08-01 to NPS-08-08)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.immunization (
    entry_uid                        UUID         PRIMARY KEY,
    patient_uid                      UUID         NOT NULL,
    -- NPS-08-01 (M): Vaccine administered or recorded (National EPI vaccine list; Other)
    vaccine_code                     VARCHAR(128),
    vaccine_text                     TEXT,
    -- NPS-08-02 (M): Whether vaccine was given (Given; Not given; Unknown; scheduled dose != administered)
    administration_status            VARCHAR(32)  NOT NULL,
    -- NPS-08-03 (M): Date vaccination occurred (Full/partial date; Unknown with reason; do not fabricate date)
    date_administered_raw            VARCHAR(64)  NOT NULL,
    date_administered_exact          DATE,
    date_administered_unknown_reason TEXT,
    -- NPS-08-04 (K): Dose within schedule (1; 2; 3; Booster; Other)
    dose_number                      VARCHAR(32),
    -- NPS-08-05 (K): Batch/lot number as recorded
    vaccine_batch                    VARCHAR(128),
    -- NPS-08-06 (K): Where vaccination information came from (EMR; Vaccination card; Patient/caregiver report; Other)
    evidence_source                  VARCHAR(32),
    evidence_source_other            TEXT,
    -- NPS-08-07 (K): Facility giving vaccine (Facility ID)
    administering_facility_id        VARCHAR(128),
    -- NPS-08-08 (O): Next planned vaccination date (Not evidence of completed dose)
    next_dose_due_date               DATE,
    change_seq                       BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                       TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.immunization                           IS 'NPS-08 (Recommended): Immunizations section.';
COMMENT ON COLUMN nps.immunization.vaccine_text              IS 'NPS-08-01 (M): Vaccine administered or recorded.';
COMMENT ON COLUMN nps.immunization.administration_status     IS 'NPS-08-02 (M): Given; Not given; Unknown. Scheduled dose != administered.';
COMMENT ON COLUMN nps.immunization.date_administered_raw     IS 'NPS-08-03 (M): Full/partial date or Unknown with reason. Do not fabricate date.';
COMMENT ON COLUMN nps.immunization.dose_number               IS 'NPS-08-04 (K): Dose within schedule (1; 2; 3; Booster; Other).';
COMMENT ON COLUMN nps.immunization.vaccine_batch             IS 'NPS-08-05 (K): Batch/lot number as recorded.';
COMMENT ON COLUMN nps.immunization.evidence_source           IS 'NPS-08-06 (K): EMR; Vaccination card; Patient/caregiver report; Other.';
COMMENT ON COLUMN nps.immunization.administering_facility_id IS 'NPS-08-07 (K): Facility giving vaccine.';
COMMENT ON COLUMN nps.immunization.next_dose_due_date        IS 'NPS-08-08 (O): Next planned vaccination date.';

-- =============================================================================
-- 12. BLOCK 09: LABORATORY & IMAGING RESULTS (NPS-09-01 to NPS-09-12)
--     Modeled as 1..* hierarchy: nps.diagnostic_report -> nps.diagnostic_result_item
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.diagnostic_report (
    entry_uid          UUID         PRIMARY KEY,
    patient_uid        UUID         NOT NULL,
    -- NPS-09-01 (M): Identifier for test report (Lab/imaging report ID; one per report)
    report_id          VARCHAR(128) NOT NULL,
    -- NPS-09-02 (M): Kind of diagnostic report (Laboratory; Imaging; Other)
    report_type        VARCHAR(32)  NOT NULL,
    -- NPS-09-03 (M): Test or imaging examination (National test list; Free text)
    test_or_study_code VARCHAR(128),
    test_or_study_text TEXT,
    -- NPS-09-04 (M): Status of result (Preliminary; Final; Corrected; Cancelled; keep corrections)
    report_status      VARCHAR(32)  NOT NULL,
    -- NPS-09-08 (K): Report-level result timestamp (When test/result applies; do not use extract time)
    result_date_time   TIMESTAMPTZ,
    -- NPS-09-11 (K): Radiology/imaging impression (Brief narrative; for imaging)
    imaging_conclusion TEXT,
    change_seq         BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.diagnostic_report                    IS 'NPS-09 (Recommended): Report-level header for laboratory and imaging results.';
COMMENT ON COLUMN nps.diagnostic_report.report_id          IS 'NPS-09-01 (M): Identifier for test report (one per report).';
COMMENT ON COLUMN nps.diagnostic_report.report_type        IS 'NPS-09-02 (M): Laboratory; Imaging; Other.';
COMMENT ON COLUMN nps.diagnostic_report.test_or_study_text IS 'NPS-09-03 (M): Test or imaging examination.';
COMMENT ON COLUMN nps.diagnostic_report.report_status      IS 'NPS-09-04 (M): Preliminary; Final; Corrected; Cancelled.';
COMMENT ON COLUMN nps.diagnostic_report.result_date_time   IS 'NPS-09-08 (K): When test/result applies. Do not use extract time.';
COMMENT ON COLUMN nps.diagnostic_report.imaging_conclusion IS 'NPS-09-11 (K): Radiology/imaging impression.';

CREATE TABLE IF NOT EXISTS nps.diagnostic_result_item (
    result_item_uid                 UUID          PRIMARY KEY DEFAULT gen_random_uuid(),
    source_item_id                  VARCHAR(128),
    report_entry_uid                UUID          NOT NULL,
    patient_uid                     UUID          NOT NULL,
    -- NPS-09-05 (M): Analyte or observation name (Hb; Malaria RDT; HIV test; Other; per reported observation)
    result_item_code                VARCHAR(128),
    result_item_text                TEXT,
    -- NPS-09-06 (M): Recorded finding (Numeric; Positive; Negative; Reactive; Non-reactive; Narrative; may be unavailable with reason)
    result_value_numeric            NUMERIC(18,6),
    result_value_choice             VARCHAR(32),
    result_value_narrative          TEXT,
    -- NPS-09-07 (K): Unit of measurement (g/dL; mmol/L; Other; required for numeric dimensional results)
    result_unit                     VARCHAR(64),
    numeric_result_is_dimensional   BOOLEAN,
    -- NPS-09-08 (K): Observation-specific result timestamp (When test/result applies; do not use extract time)
    result_date_time                TIMESTAMPTZ,
    -- NPS-09-09 (K): Applicable laboratory reference (Low-High; Narrative)
    reference_range                 TEXT,
    -- NPS-09-10 (K): Interpretation documented by laboratory (High; Low; Normal; Abnormal; Narrative; do not auto-interpret)
    interpretation                  TEXT,
    -- NPS-09-12 (K): Why result value absent (Pending; Not recorded; Withheld; Other; distinguish from negative)
    result_unavailable_reason       VARCHAR(32),
    result_unavailable_reason_other TEXT,
    change_seq                      BIGINT        NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.diagnostic_result_item                           IS 'NPS-09 (Recommended): Per-observation / analyte findings belonging to a diagnostic report.';
COMMENT ON COLUMN nps.diagnostic_result_item.result_item_text          IS 'NPS-09-05 (M): Analyte or observation name (Hb; Malaria RDT; HIV test; Other).';
COMMENT ON COLUMN nps.diagnostic_result_item.result_value_numeric      IS 'NPS-09-06 (M): Numeric recorded finding.';
COMMENT ON COLUMN nps.diagnostic_result_item.result_value_choice       IS 'NPS-09-06 (M): Choice finding (Positive; Negative; Reactive; Non-reactive).';
COMMENT ON COLUMN nps.diagnostic_result_item.result_value_narrative    IS 'NPS-09-06 (M): Narrative finding.';
COMMENT ON COLUMN nps.diagnostic_result_item.result_unit               IS 'NPS-09-07 (K): Unit of measurement (required for numeric dimensional results).';
COMMENT ON COLUMN nps.diagnostic_result_item.result_date_time          IS 'NPS-09-08 (K): When test/result applies.';
COMMENT ON COLUMN nps.diagnostic_result_item.reference_range           IS 'NPS-09-09 (K): Applicable laboratory reference.';
COMMENT ON COLUMN nps.diagnostic_result_item.interpretation            IS 'NPS-09-10 (K): Interpretation documented by laboratory. Do not auto-interpret.';
COMMENT ON COLUMN nps.diagnostic_result_item.result_unavailable_reason IS 'NPS-09-12 (K): Pending; Not recorded; Withheld; Other. Distinguish from negative.';

-- =============================================================================
-- 13. BLOCK 10: HISTORY OF PROCEDURES (NPS-10-01 to NPS-10-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.procedure_history (
    entry_uid              UUID         PRIMARY KEY,
    patient_uid            UUID         NOT NULL,
    -- NPS-10-01 (M): Significant clinical procedure (Approved procedure list; Free text)
    procedure_code         VARCHAR(128),
    procedure_text         TEXT,
    -- NPS-10-02 (M): Whether procedure occurred (Completed; In progress; Not done; Unknown; order != completed procedure)
    procedure_status       VARCHAR(32)  NOT NULL,
    -- NPS-10-03 (K): When performed (Full/partial date or date/time)
    procedure_date_raw     VARCHAR(64),
    procedure_date_time    TIMESTAMPTZ,
    -- NPS-10-04 (K): Facility where performed (Facility ID)
    performing_facility_id VARCHAR(128),
    -- NPS-10-05 (K): Documented result of procedure (Free text; do not infer)
    outcome                TEXT,
    -- NPS-10-06 (K): Documented complications (Free text; None documented; only if assessed)
    complications          TEXT,
    change_seq             BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at             TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.procedure_history                        IS 'NPS-10 (Recommended): History of significant clinical procedures.';
COMMENT ON COLUMN nps.procedure_history.procedure_text         IS 'NPS-10-01 (M): Significant clinical procedure.';
COMMENT ON COLUMN nps.procedure_history.procedure_status       IS 'NPS-10-02 (M): Completed; In progress; Not done; Unknown. Order != completed procedure.';
COMMENT ON COLUMN nps.procedure_history.procedure_date_raw     IS 'NPS-10-03 (K): When performed (full/partial date).';
COMMENT ON COLUMN nps.procedure_history.performing_facility_id IS 'NPS-10-04 (K): Facility where performed.';
COMMENT ON COLUMN nps.procedure_history.outcome                IS 'NPS-10-05 (K): Documented result of procedure. Do not infer.';
COMMENT ON COLUMN nps.procedure_history.complications          IS 'NPS-10-06 (K): Documented complications (Free text; None documented).';

-- =============================================================================
-- 14. BLOCK 11: MEDICAL DEVICES (NPS-11-01 to NPS-11-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.medical_device (
    entry_uid         UUID         PRIMARY KEY,
    patient_uid       UUID         NOT NULL,
    -- NPS-11-01 (M): Implanted or clinically relevant assistive device (Pacemaker; Implant; Prosthesis; Other)
    device_type_code  VARCHAR(128),
    device_type_text  TEXT,
    -- NPS-11-02 (M): Whether device is currently used (Active; Stopped; Completed; Unknown; unknown removal != active)
    device_use_status VARCHAR(32)  NOT NULL,
    -- NPS-11-03 (K): Start of device use (Recorded date)
    date_started_raw  VARCHAR(32),
    date_started      DATE,
    -- NPS-11-04 (K): End of device use (Recorded date)
    date_stopped_raw  VARCHAR(32),
    date_stopped      DATE,
    -- NPS-11-05 (K): Where device is used (Free text)
    body_site         TEXT,
    -- NPS-11-06 (O): Device model or recorded identifier (Model; Serial number if available)
    device_identifier TEXT,
    change_seq        BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.medical_device                   IS 'NPS-11 (Recommended): Implanted or clinically relevant assistive medical devices.';
COMMENT ON COLUMN nps.medical_device.device_type_text  IS 'NPS-11-01 (M): Implanted or clinically relevant assistive device. Exclude routine facility equipment.';
COMMENT ON COLUMN nps.medical_device.device_use_status IS 'NPS-11-02 (M): Active; Stopped; Completed; Unknown.';
COMMENT ON COLUMN nps.medical_device.date_started_raw  IS 'NPS-11-03 (K): Date inserted/started.';
COMMENT ON COLUMN nps.medical_device.date_stopped_raw  IS 'NPS-11-04 (K): Date removed/stopped.';
COMMENT ON COLUMN nps.medical_device.body_site         IS 'NPS-11-05 (K): Body site where device is used.';
COMMENT ON COLUMN nps.medical_device.device_identifier IS 'NPS-11-06 (O): Device model or serial number if available.';

-- =============================================================================
-- 15. BLOCK 12: ALERTS (NPS-12-01 to NPS-12-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.clinical_alert (
    entry_uid                UUID         PRIMARY KEY,
    patient_uid              UUID         NOT NULL,
    -- NPS-12-01 (M): Clinically important recorded warning (Free text; only explicitly documented alerts)
    alert_description        TEXT         NOT NULL,
    -- NPS-12-02 (M): Nature of alert (Clinical; Infection prevention; Safety; Other)
    alert_category           VARCHAR(32)  NOT NULL,
    -- NPS-12-03 (M): Whether alert remains applicable (Active; Inactive; Resolved; Unknown; no automatic inference)
    alert_status             VARCHAR(32)  NOT NULL,
    -- NPS-12-04 (M): Person/system recording alert (Provider ID; Facility; Source system)
    alert_source             TEXT         NOT NULL,
    -- NPS-12-05 (K): When alert applies (Recorded date)
    effective_date_raw       VARCHAR(32),
    effective_date           DATE,
    -- NPS-12-06 (O): Related allergy/problem if any (Clinical entry ID)
    linked_entry_uid         UUID,
    linked_clinical_entry_id VARCHAR(128),
    change_seq               BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.clinical_alert                          IS 'NPS-12 (Recommended): Explicitly documented clinical, infection prevention, and safety alerts.';
COMMENT ON COLUMN nps.clinical_alert.alert_description        IS 'NPS-12-01 (M): Clinically important recorded warning.';
COMMENT ON COLUMN nps.clinical_alert.alert_category           IS 'NPS-12-02 (M): Clinical; Infection prevention; Safety; Other.';
COMMENT ON COLUMN nps.clinical_alert.alert_status             IS 'NPS-12-03 (M): Active; Inactive; Resolved; Unknown.';
COMMENT ON COLUMN nps.clinical_alert.alert_source             IS 'NPS-12-04 (M): Person/system recording alert.';
COMMENT ON COLUMN nps.clinical_alert.effective_date_raw       IS 'NPS-12-05 (K): When alert applies.';
COMMENT ON COLUMN nps.clinical_alert.linked_clinical_entry_id IS 'NPS-12-06 (O): Related allergy/problem clinical entry ID.';

-- =============================================================================
-- 16. BLOCK 13: ADVANCE DIRECTIVES (NPS-13-01 to NPS-13-04)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.advance_directive (
    entry_uid             UUID         PRIMARY KEY,
    patient_uid           UUID         NOT NULL,
    -- NPS-13-01 (M): Documented care preference or directive (Free text; only when documented)
    directive_preference  TEXT         NOT NULL,
    -- NPS-13-02 (M): Status of documented preference (Active; Superseded; Withdrawn; Unknown)
    directive_status      VARCHAR(32)  NOT NULL,
    -- NPS-13-03 (M): Origin of directive (Patient statement; Clinical document; Legal document; Other)
    evidence_source       VARCHAR(32)  NOT NULL,
    evidence_source_other TEXT,
    -- NPS-13-04 (K): When recorded (Recorded date)
    date_recorded_raw     VARCHAR(32),
    date_recorded         DATE,
    change_seq            BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.advance_directive                      IS 'NPS-13 (Optional): Documented care preferences and advance directives.';
COMMENT ON COLUMN nps.advance_directive.directive_preference IS 'NPS-13-01 (M): Documented care preference or directive.';
COMMENT ON COLUMN nps.advance_directive.directive_status     IS 'NPS-13-02 (M): Active; Superseded; Withdrawn; Unknown.';
COMMENT ON COLUMN nps.advance_directive.evidence_source      IS 'NPS-13-03 (M): Patient statement; Clinical document; Legal document; Other.';
COMMENT ON COLUMN nps.advance_directive.date_recorded_raw    IS 'NPS-13-04 (K): Date recorded.';

-- =============================================================================
-- 17. BLOCK 14: FUNCTIONAL STATUS (NPS-14-01 to NPS-14-04)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.functional_status (
    entry_uid                      UUID          PRIMARY KEY,
    patient_uid                    UUID          NOT NULL,
    -- NPS-14-01 (M): Domain assessed (Mobility; Self-care; Communication; Other)
    function_assessed              VARCHAR(64)   NOT NULL,
    function_assessed_other        TEXT,
    -- NPS-14-02 (M): Documented functional ability (Independent; Needs assistance; Narrative; Score)
    finding_text                   TEXT          NOT NULL,
    finding_score                  NUMERIC(10,2),
    -- NPS-14-03 (M): When assessed (Recorded date; Unknown with reason)
    assessment_date_raw            VARCHAR(64)   NOT NULL,
    assessment_date                DATE,
    assessment_date_unknown_reason TEXT,
    -- NPS-14-04 (K): Help or support required (Free text)
    assistance_needed              TEXT,
    change_seq                     BIGINT        NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                     TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.functional_status                     IS 'NPS-14 (Optional): Functional status assessments.';
COMMENT ON COLUMN nps.functional_status.function_assessed   IS 'NPS-14-01 (M): Mobility; Self-care; Communication; Other.';
COMMENT ON COLUMN nps.functional_status.finding_text        IS 'NPS-14-02 (M): Documented functional ability. No inference from diagnosis.';
COMMENT ON COLUMN nps.functional_status.assessment_date_raw IS 'NPS-14-03 (M): Recorded date or Unknown with reason.';
COMMENT ON COLUMN nps.functional_status.assistance_needed   IS 'NPS-14-04 (K): Help or support required.';

-- =============================================================================
-- 18. BLOCK 15: PREGNANCY HISTORY (NPS-15-01 — Reserved Pending Approval)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.pregnancy_history_reserved (
    reserved_uid      UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_uid       UUID         NOT NULL UNIQUE,
    -- NPS-15-01 (—): Reserved maternal health section.
    -- Source document does not define detailed fields; do not invent a dataset.
    governance_status VARCHAR(128) NOT NULL DEFAULT 'Pending approved maternal-health data dictionary',
    change_seq        BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.pregnancy_history_reserved                   IS 'NPS-15 (Optional - pending approval): Reserved maternal health block. No clinical fields invented.';
COMMENT ON COLUMN nps.pregnancy_history_reserved.governance_status IS 'NPS-15-01 (—): Pending approved maternal-health data dictionary.';

-- =============================================================================
-- 19. BLOCK 16: SOCIAL HISTORY (NPS-16-01 to NPS-16-05)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.social_history (
    entry_uid                UUID         PRIMARY KEY,
    patient_uid              UUID         NOT NULL,
    -- NPS-16-01 (M): Topic recorded (Tobacco; Alcohol; Other relevant topic)
    social_history_topic     VARCHAR(64)  NOT NULL,
    topic_other              TEXT,
    -- NPS-16-02 (M): Patient-reported status or quantity (Current; Former; Never; Unknown; Other; Unknown != never)
    reported_response        TEXT         NOT NULL,
    -- NPS-16-03 (M): Who provided information (Patient; Caregiver; Clinician; Other)
    information_source       VARCHAR(32)  NOT NULL,
    information_source_other TEXT,
    -- NPS-16-04 (K): When history was obtained (Recorded date)
    observation_date_raw     VARCHAR(32),
    observation_date         DATE,
    -- NPS-16-05 (K): Amount or frequency reported (As recorded; no inference)
    frequency_quantity       TEXT,
    change_seq               BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.social_history                      IS 'NPS-16 (Optional): Social history observations.';
COMMENT ON COLUMN nps.social_history.social_history_topic IS 'NPS-16-01 (M): Tobacco; Alcohol; Other relevant topic.';
COMMENT ON COLUMN nps.social_history.reported_response    IS 'NPS-16-02 (M): Current; Former; Never; Unknown; Other. Unknown != never.';
COMMENT ON COLUMN nps.social_history.information_source   IS 'NPS-16-03 (M): Patient; Caregiver; Clinician; Other.';
COMMENT ON COLUMN nps.social_history.observation_date_raw IS 'NPS-16-04 (K): When history was obtained.';
COMMENT ON COLUMN nps.social_history.frequency_quantity   IS 'NPS-16-05 (K): Amount or frequency reported as recorded.';

-- =============================================================================
-- 20. BLOCK 17: CARE PLAN & FOLLOW-UP (NPS-17-01 to NPS-17-07)
--     Modeled as 1..* hierarchy: nps.care_plan -> nps.care_plan_action
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.care_plan (
    entry_uid         UUID         PRIMARY KEY,
    patient_uid       UUID         NOT NULL,
    -- NPS-17-01 (M): Identifier of documented care plan (Plan ID; per existing plan)
    care_plan_id      VARCHAR(128) NOT NULL,
    -- NPS-17-02 (M): Documented plan or instructions (Free text; do not generate treatment advice)
    care_plan_summary TEXT         NOT NULL,
    -- NPS-17-03 (M): Progress of plan (Active; Completed; Cancelled; Unknown)
    plan_status       VARCHAR(32)  NOT NULL,
    change_seq        BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at        TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.care_plan                   IS 'NPS-17 (Optional): Care plan header.';
COMMENT ON COLUMN nps.care_plan.care_plan_id      IS 'NPS-17-01 (M): Identifier of documented care plan.';
COMMENT ON COLUMN nps.care_plan.care_plan_summary IS 'NPS-17-02 (M): Documented plan or instructions. Do not generate treatment advice.';
COMMENT ON COLUMN nps.care_plan.plan_status       IS 'NPS-17-03 (M): Active; Completed; Cancelled; Unknown.';

CREATE TABLE IF NOT EXISTS nps.care_plan_action (
    action_uid              UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    source_action_id VARCHAR(128),
    care_plan_entry_uid     UUID         NOT NULL,
    patient_uid             UUID         NOT NULL,
    -- NPS-17-04 (K): Specific follow-up or referral activity (Review; Referral; Investigation; Other; only if recorded)
    planned_action_category VARCHAR(32)  NOT NULL,
    planned_action_text     TEXT         NOT NULL,
    -- NPS-17-05 (K): Progress of planned action (Pending; In progress; Completed; Cancelled)
    action_status           VARCHAR(32),
    -- NPS-17-06 (K): Date action is expected (Recorded date)
    due_date_raw            VARCHAR(32),
    due_date                DATE,
    -- NPS-17-07 (K): Referral destination (Facility ID; if applicable)
    receiving_facility_id   VARCHAR(128),
    change_seq              BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.care_plan_action                       IS 'NPS-17 (Optional): Specific follow-up or referral actions belonging to a care plan.';
COMMENT ON COLUMN nps.care_plan_action.planned_action_text   IS 'NPS-17-04 (K): Specific follow-up or referral activity (Review; Referral; Investigation; Other).';
COMMENT ON COLUMN nps.care_plan_action.action_status         IS 'NPS-17-05 (K): Pending; In progress; Completed; Cancelled.';
COMMENT ON COLUMN nps.care_plan_action.due_date_raw          IS 'NPS-17-06 (K): Date action is expected.';
COMMENT ON COLUMN nps.care_plan_action.receiving_facility_id IS 'NPS-17-07 (K): Referral destination facility ID.';

-- =============================================================================
-- 21. BLOCK 18: PAST PROBLEMS (NPS-18-01 to NPS-18-04)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.past_problem (
    entry_uid                    UUID         PRIMARY KEY,
    patient_uid                  UUID         NOT NULL,
    -- NPS-18-01 (M): Previously relevant health condition (Approved diagnosis list; Free text; reference existing problem where possible)
    past_condition_code          VARCHAR(128),
    past_condition_text          TEXT,
    referenced_problem_entry_uid UUID,
    -- NPS-18-02 (M): Past condition status (Resolved; Inactive; Unknown; do not duplicate active problems)
    historical_status            VARCHAR(32)  NOT NULL,
    -- NPS-18-03 (K): When condition began or resolved (Recorded date(s))
    onset_date_raw               VARCHAR(32),
    onset_date                   DATE,
    resolution_date_raw          VARCHAR(32),
    resolution_date              DATE,
    -- NPS-18-04 (K): Clinically relevant sequelae (Free text)
    lasting_effects              TEXT,
    change_seq                   BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.past_problem                     IS 'NPS-18 (Optional): Past problems (resolved or inactive historical conditions).';
COMMENT ON COLUMN nps.past_problem.past_condition_text IS 'NPS-18-01 (M): Previously relevant health condition.';
COMMENT ON COLUMN nps.past_problem.historical_status   IS 'NPS-18-02 (M): Resolved; Inactive; Unknown. Do not duplicate active problems.';
COMMENT ON COLUMN nps.past_problem.onset_date_raw      IS 'NPS-18-03 (K): When condition began.';
COMMENT ON COLUMN nps.past_problem.resolution_date_raw IS 'NPS-18-03 (K): When condition resolved.';
COMMENT ON COLUMN nps.past_problem.lasting_effects     IS 'NPS-18-04 (K): Clinically relevant sequelae.';

-- =============================================================================
-- 22. BLOCK 19: PATIENT STORY (NPS-19-01 to NPS-19-05)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.patient_story (
    entry_uid                    UUID         PRIMARY KEY,
    patient_uid                  UUID         NOT NULL,
    -- NPS-19-01 (M): Patient-attributed clinical context (Brief free text; do not turn narrative into diagnosis)
    patient_narrative            TEXT         NOT NULL,
    -- NPS-19-02 (M): Who provided the story (Patient; Caregiver; Other; attribution required)
    information_source           VARCHAR(32)  NOT NULL,
    information_source_other     TEXT,
    -- NPS-19-03 (M): When narrative was recorded (Recorded date or date/time; Unknown with reason)
    date_recorded_raw            VARCHAR(64)  NOT NULL,
    date_recorded_time           TIMESTAMPTZ,
    date_recorded_unknown_reason TEXT,
    -- NPS-19-04 (M): Language used for story (English; Krio; Other (specify); preserve original wording)
    language_used                VARCHAR(32)  NOT NULL,
    language_other               VARCHAR(100),
    -- NPS-19-05 (K): Patient-stated concerns or goals (Free text)
    patient_priorities           TEXT,
    change_seq                   BIGINT       NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                   TIMESTAMPTZ  NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.patient_story                    IS 'NPS-19 (Optional): Patient-attributed clinical narrative and stated priorities.';
COMMENT ON COLUMN nps.patient_story.patient_narrative  IS 'NPS-19-01 (M): Patient-attributed clinical context. Do not turn narrative into diagnosis.';
COMMENT ON COLUMN nps.patient_story.information_source IS 'NPS-19-02 (M): Patient; Caregiver; Other. Attribution required.';
COMMENT ON COLUMN nps.patient_story.date_recorded_raw  IS 'NPS-19-03 (M): Recorded date/time or Unknown with reason.';
COMMENT ON COLUMN nps.patient_story.language_used      IS 'NPS-19-04 (M): English; Krio; Other (specify). Preserve original wording.';
COMMENT ON COLUMN nps.patient_story.patient_priorities IS 'NPS-19-05 (K): Patient-stated concerns or goals.';

-- =============================================================================
-- 23. BLOCK 20: VITAL SIGNS (NPS-20-01 to NPS-20-06)
-- =============================================================================
CREATE TABLE IF NOT EXISTS nps.vital_sign (
    entry_uid                       UUID          PRIMARY KEY,
    patient_uid                     UUID          NOT NULL,
    -- NPS-20-01 (M): Measurement being recorded (BP; Pulse; Respiratory rate; Temperature; SpO2; Weight; Height; Other)
    vital_sign                      VARCHAR(32)   NOT NULL,
    vital_sign_other                VARCHAR(100),
    -- NPS-20-02 (M): Measured value (Recorded value; Unknown with reason; BP requires systolic and diastolic values)
    value_raw                       VARCHAR(64)   NOT NULL,
    value_numeric                   NUMERIC(10,2),
    bp_systolic                     SMALLINT,
    bp_diastolic                    SMALLINT,
    value_unknown_reason            TEXT,
    -- NPS-20-03 (M): Unit for measurement (mmHg; beats/min; breaths/min; °C; %; kg; cm; required for dimensional numbers)
    unit                            VARCHAR(32),
    unit_other                      VARCHAR(32),
    -- NPS-20-04 (M): When measured (Recorded date/time; Unknown with reason; not NPS generation date)
    measurement_date_raw            VARCHAR(64)   NOT NULL,
    measurement_date_time           TIMESTAMPTZ,
    measurement_date_unknown_reason TEXT,
    -- NPS-20-05 (K): Position at measurement (Sitting; Standing; Lying; Unknown)
    body_position                   VARCHAR(32),
    -- NPS-20-06 (O): How measurement obtained (Free text)
    measurement_method              TEXT,
    change_seq                      BIGINT        NOT NULL DEFAULT nextval('nps.sync_change_seq'),
    created_at                      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                      TIMESTAMPTZ   NOT NULL DEFAULT CURRENT_TIMESTAMP
);

COMMENT ON TABLE  nps.vital_sign                      IS 'NPS-20 (Optional): Vital signs measurements.';
COMMENT ON COLUMN nps.vital_sign.vital_sign           IS 'NPS-20-01 (M): BP; Pulse; Respiratory rate; Temperature; SpO2; Weight; Height; Other.';
COMMENT ON COLUMN nps.vital_sign.value_raw            IS 'NPS-20-02 (M): Measured value or Unknown with reason. BP requires systolic and diastolic values.';
COMMENT ON COLUMN nps.vital_sign.bp_systolic          IS 'NPS-20-02 (M): Systolic blood pressure when vital_sign = BP.';
COMMENT ON COLUMN nps.vital_sign.bp_diastolic         IS 'NPS-20-02 (M): Diastolic blood pressure when vital_sign = BP.';
COMMENT ON COLUMN nps.vital_sign.unit                 IS 'NPS-20-03 (M): mmHg; beats/min; breaths/min; °C; %; kg; cm.';
COMMENT ON COLUMN nps.vital_sign.measurement_date_raw IS 'NPS-20-04 (M): Recorded date/time or Unknown with reason. Not NPS generation date.';
COMMENT ON COLUMN nps.vital_sign.body_position        IS 'NPS-20-05 (K): Sitting; Standing; Lying; Unknown.';
COMMENT ON COLUMN nps.vital_sign.measurement_method   IS 'NPS-20-06 (O): How measurement was obtained.';

-- =============================================================================
-- 24. Release archive and patient change tracking (technical metadata)
-- =============================================================================
CREATE TABLE nps.summary_release (
    document_uid UUID PRIMARY KEY REFERENCES nps.summary_document,
    patient_revision BIGINT NOT NULL CHECK (patient_revision > 0),
    standard_payload JSONB,
    restricted_payload JSONB NOT NULL,
    released_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE nps.patient_revision (
    patient_uid UUID PRIMARY KEY REFERENCES nps.patient,
    revision BIGINT NOT NULL DEFAULT 1 CHECK (revision > 0),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

COMMENT ON COLUMN nps.section_completeness.absence_evidence_ref IS
    'NPS-03-02: Internal source reference supporting an explicit None known assessment.';
COMMENT ON COLUMN nps.diagnostic_result_item.numeric_result_is_dimensional IS
    'NPS-09-07: Source/terminology classification of a numeric result. Null means unclassified.';

COMMIT;
