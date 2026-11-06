# DHIS2 EMR Connector

This project has two components for the Sierra Leone EMR.

- **DHIS2 connection check** uses Java 21, Spring Boot, and Maven to verify service-account authentication through a local endpoint.
- **National Patient Summary (NPS) SQL** defines a PostgreSQL reference schema and generates a versioned patient summary from records loaded into it. See [NPS setup and demo](#national-patient-summary-nps-sql).

The Java connector builds as an executable JAR at `target/dhis2-emr-connector.jar`.

## Requirements

- JDK 21 or newer. Maven uses `JAVA_HOME`, not whichever `java` appears first on `PATH`.
- Maven 3.6.3 or newer.
- An approved least-privilege DHIS2 service account. Do not use a personal administrator account for the connector.

On this workstation, `JAVA_HOME` may still point at JDK 17 while `java` on `PATH` is JDK 21. Point Maven at JDK 21 before building:

```powershell
$env:JAVA_HOME = "C:\Program Files\Java\jdk-21.0.12"
$env:Path = "$env:JAVA_HOME\bin;" + $env:Path
java -version
mvn -version
```

`mvn -version` must report Java 21. Use the JDK 21 path installed on the machine you are using.

## Configure credentials

Set these in the shell that starts the JAR. Do not put them in source files, `application.yml`, or Git, and do not enable HTTP client debug logging (that can print the `Authorization` header).

```powershell
$env:DHIS2_BASE_URL = "https://dhis.mohs.gov.sl/hmis"
$env:DHIS2_USERNAME = "ENTER_YOUR_APPROVED_USERNAME"
$env:DHIS2_PASSWORD = "ENTER_YOUR_PASSWORD"
```

Optional timeouts, if the defaults of 5 seconds to connect and 20 seconds to read are not enough:

```powershell
$env:DHIS2_CONNECT_TIMEOUT = "5s"
$env:DHIS2_READ_TIMEOUT = "20s"
```

If `DHIS2_BASE_URL` is omitted, the connector uses `https://dhis.mohs.gov.sl/hmis`. Username and password are required. The base URL must be HTTPS and must not contain a username, password, query string, or fragment. The context path is part of the URL: the check calls `{DHIS2_BASE_URL}/api/me`, which is `https://dhis.mohs.gov.sl/hmis/api/me` for the Ministry HMIS.

Authentication is HTTP Basic over HTTPS, using the JVM trust store. Certificate verification is enabled. This server rejects an invalid Basic credential with HTTP 401 and sends a browser with no credentials to the DHIS2 login page. Confirm with the SAN team that Basic authentication remains the approved method for the service account before deployment. A personal access token or OAuth would replace this header later; do not invent that configuration here.

## Build, test, and run

```powershell
mvn clean package
java -jar target/dhis2-emr-connector.jar
```

`mvn clean package` also runs the automated tests. The tests use mocked HTTP responses and do not contact DHIS2.

In a second PowerShell window:

```powershell
Invoke-RestMethod http://127.0.0.1:8080/actuator/health
Invoke-RestMethod http://127.0.0.1:8080/internal/dhis2/check
```

The application listens on the loopback address only. Use `127.0.0.1`, not a LAN address. `GET /actuator/health` is the local process health check. `GET /internal/dhis2/check` calls DHIS2 `GET /api/me` and returns whether that authentication succeeded. Neither endpoint should be published outside the host. Do not put the connector or PostgreSQL on ngrok for this test.

A successful DHIS2 check returns HTTP 200:

```json
{"status":"connected","message":"DHIS2 authentication succeeded"}
```

The response does not include the DHIS2 user profile. Health looks like:

```json
{"status":"UP"}
```

Windows PowerShell 5.1 throws on an error status and does not print the JSON body. Read that body with:

```powershell
try {
  Invoke-RestMethod http://127.0.0.1:8080/internal/dhis2/check
} catch [System.Net.WebException] {
  $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
  $reader.ReadToEnd()
  $reader.Close()
}
```

`curl.exe` prints the body and status directly. Use `curl.exe`, not the `curl` alias:

```powershell
curl.exe -sS -w "\nHTTP_STATUS:%{http_code}\n" http://127.0.0.1:8080/internal/dhis2/check
```

## How to read a failed check

The connector translates DHIS2 and network failures into a short JSON message. It does not return credentials, the `Authorization` header, or the raw DHIS2 error body.

| What you see | What it means |
| --- | --- |
| HTTP 200, `connected` | Basic authentication worked and `GET /api/me` returned success. |
| HTTP 502, `DHIS2 rejected the configured credentials` | DHIS2 returned HTTP 401. Check the service-account username and password. The connector does not use your Windows login. |
| HTTP 502, `does not have permission` | DHIS2 returned HTTP 403. The account authenticated but is not allowed to call this API. Ask SAN for the minimum role that can read the current user. |
| HTTP 502, `could not find the authentication endpoint` | DHIS2 returned HTTP 404. `DHIS2_BASE_URL` is probably missing `/hmis` or points at the wrong path. `https://dhis.mohs.gov.sl/api/me` is not the HMIS API. |
| HTTP 502, `redirected the connection check` | DHIS2 sent the login-page redirect instead of an API response. The request was not accepted as authenticated API traffic. Check the base URL and credentials. |
| HTTP 502, `unsuccessful response` | DHIS2 returned some other HTTP error. The connector log names the failure category, not the response body. |
| HTTP 504, `did not respond before the timeout` | The TCP connection or the response exceeded the configured timeout. Check firewall, proxy, and SAN availability before increasing `DHIS2_CONNECT_TIMEOUT` or `DHIS2_READ_TIMEOUT`. |
| HTTP 502, `Unable to reach DHIS2` | DNS failed or the TCP connection did not stay open. The connector log `cause=` is `UnknownHostException` for DNS. `ConnectException` or `ClosedChannelException` means the host did not accept the connection. |
| HTTP 502, `trusted TLS connection` | The certificate chain was not trusted. Do not disable certificate verification. Confirm the host and the JVM trust store with SAN. |
| Process exits during startup mentioning username, password, or HTTPS | `DHIS2_USERNAME` or `DHIS2_PASSWORD` is missing, or the base URL is not an absolute HTTPS URL. |

Stop the connector with Ctrl+C in the window where the JAR is running.

## Run the same JAR on another authorized server

Copy `dhis2-emr-connector.jar` and run it with JDK 21. Set the same environment variables in that server's service account environment. The process still binds to loopback until SAN approves the deployment architecture and EMR-to-connector authentication. Do not open port 8080 on a network interface for this test.

No dataset UID, data-element UID, category option combination, organisation unit, or reporting period is configured. The connector has no summary-submission endpoint and does not connect to the DHIS2 database.

## National Patient Summary (NPS) SQL

The [NPS SQL package](emr-nps-sql/) maps 149 data dictionary elements across 20 blocks. It creates the `nps` schema, stores clinical records and their sources, and assembles a versioned patient summary in JSON. It also includes access controls, audit logging, validation queries, and a queue that tracks retries and receipts for offline synchronisation.

The SQL package runs separately in PostgreSQL 17 or later. Connecting it to the live EMR and exchanging summaries with the Shared Health Record (SHR) require the source-field mapping, an authenticated Spring Boot integration, and the approved SHR transport endpoint.

### Set up the demo in pgAdmin

1. On a local PostgreSQL test server, create an empty database named `nps_demo`.
2. Open **Query Tool** on `nps_demo` with your local PostgreSQL administrator login. This login must be able to create the database roles and run the fixtures under those roles.
3. Open and execute the files in [`emr-nps-sql/sql`](emr-nps-sql/sql/) once in order, starting with `001_create_schema.sql` and ending with `009_security.sql`.
4. Open and execute [`synthetic_test_data.sql`](emr-nps-sql/tests/synthetic_test_data.sql) once. It loads fictional patient records and publishes the example summaries.

### Show the patient summary

After setup, open a new **Query Tool** tab on `nps_demo` and execute the complete query below.

```sql
WITH demo AS (
    SELECT nps.get_patient_summary(
        '00000000-0000-4000-8000-000000000001'::uuid
    ) AS summary
)
SELECT
    summary #>> '{documentAndProvenance,nps0101DocumentId}' AS document_id,
    jsonb_array_length(
        summary #> '{clinicalSections,laboratoryAndImagingResults,reports}'
    ) AS lab_and_imaging_reports,
    summary #>> '{clinicalSections,patientStory,nps0302SectionInformationStatus}' AS patient_story,
    jsonb_pretty(summary) AS full_patient_summary
FROM demo;
```

**Expected result.** One row for `SYNTHETIC-DOC-1`, with **2** lab and imaging reports and **Withheld** for the patient story. The last column contains the full JSON. [Example summary](emr-nps-sql/examples/patient_summary_example.json)

### Run the SQL tests

With the synthetic data loaded in `nps_demo`, execute each test file in pgAdmin.

- [`patient_summary_tests.sql`](emr-nps-sql/tests/patient_summary_tests.sql) checks patient lookup, corrected records, access restrictions, and audit entries.
- [`offline_sync_test.sql`](emr-nps-sql/tests/offline_sync_test.sql) checks retries, duplicate deliveries, receipts, and invalidation.

Successful test runs finish without an SQL error. Both scripts roll back their test changes, so the original synthetic demo remains available.

