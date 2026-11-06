# DHIS2 EMR Connector

Java 21, Spring Boot, and Maven connector for the Sierra Leone EMR. This version authenticates to DHIS2 and exposes a local connection check. It does not submit summary data.

The packaged artifact is an executable JAR:

`target/dhis2-emr-connector.jar`

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

## Still to confirm with SAN

- The service account may use HTTP Basic over HTTPS, and which roles it needs.
- Dataset UID, data-element UIDs, category option combinations, facility organisation-unit identifiers, and reporting-period rules.
- Where the connector will run, and how the EMR will authenticate to it.

Do not guess those identifiers and do not submit EMR summary data before they are confirmed.
