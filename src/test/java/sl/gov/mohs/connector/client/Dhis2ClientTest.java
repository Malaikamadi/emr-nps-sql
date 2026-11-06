package sl.gov.mohs.connector.client;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.catchThrowable;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.header;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.method;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withException;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

import java.net.ConnectException;
import java.net.URI;
import java.net.UnknownHostException;
import java.net.http.HttpTimeoutException;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.Base64;
import javax.net.ssl.SSLHandshakeException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpMethod;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;
import sl.gov.mohs.connector.config.Dhis2ClientConfig;
import sl.gov.mohs.connector.config.Dhis2Properties;
import sl.gov.mohs.connector.controller.Dhis2CheckController;

@ExtendWith(OutputCaptureExtension.class)
class Dhis2ClientTest {
    private static final String SECRET = "super-secret-value";
    private static final URI CURRENT_USER = URI.create("https://dhis.example/hmis/api/me");

    @Test
    void buildsCurrentUserUriUnderTheConfiguredContextPath() {
        assertThat(Dhis2Urls.currentUser(URI.create("https://dhis.mohs.gov.sl/hmis")))
                .isEqualTo(URI.create("https://dhis.mohs.gov.sl/hmis/api/me"));
        assertThat(Dhis2Urls.currentUser(URI.create("https://dhis.mohs.gov.sl/hmis/")))
                .isEqualTo(URI.create("https://dhis.mohs.gov.sl/hmis/api/me"));
        assertThat(Dhis2Urls.currentUser(URI.create("https://dhis.example:8443/hmis")))
                .isEqualTo(URI.create("https://dhis.example:8443/hmis/api/me"));
        assertThat(Dhis2Urls.currentUser(URI.create("https://dhis.example")))
                .isEqualTo(URI.create("https://dhis.example/api/me"));
        assertThat(Dhis2Urls.currentUser(URI.create("https://user:" + SECRET + "@dhis.example/hmis?token=" + SECRET)))
                .isEqualTo(URI.create("https://dhis.example/hmis/api/me"));
    }

    @Test
    void authenticationCheckSendsBasicAuthAndDoesNotReturnTheUserProfile(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andExpect(method(HttpMethod.GET))
                .andExpect(header(HttpHeaders.AUTHORIZATION, harness.authorization))
                .andExpect(header(HttpHeaders.ACCEPT, MediaType.APPLICATION_JSON_VALUE))
                .andRespond(withSuccess("{\"id\":\"abc\",\"password\":\"" + SECRET + "\"}", MediaType.APPLICATION_JSON));

        ResponseEntity<java.util.Map<String, String>> response = harness.controller.checkConnection();

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsExactlyInAnyOrderEntriesOf(java.util.Map.of(
                "status", "connected",
                "message", "DHIS2 authentication succeeded"));
        assertThat(response.getBody().values()).allSatisfy(value -> assertThat(value).doesNotContain(SECRET));
        assertNoSecrets(output, harness.authorization);
        harness.server.verify();
    }

    @Test
    void invalidCredentialsAreReportedWithoutTheResponseBody(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withStatus(HttpStatus.UNAUTHORIZED)
                        .contentType(MediaType.APPLICATION_JSON)
                        .body("{\"message\":\"" + SECRET + "\"}"));

        ResponseEntity<java.util.Map<String, String>> response = harness.controller.checkConnection();

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_GATEWAY);
        assertThat(response.getBody()).containsEntry("status", "error")
                .containsEntry("message", "DHIS2 rejected the configured credentials");
        assertThat(response.getBody().values()).allSatisfy(value -> assertThat(value).doesNotContain(SECRET));
        assertNoSecrets(output, harness.authorization);
        harness.server.verify();
    }

    @Test
    void insufficientPermissionsAreReportedSafely(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withStatus(HttpStatus.FORBIDDEN)
                        .contentType(MediaType.APPLICATION_JSON)
                        .body("{\"message\":\"" + SECRET + "\"}"));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.FORBIDDEN);
        assertThat(thrown.getMessage()).isEqualTo("The DHIS2 account does not have permission to access this API");
        assertThat(thrown.getCause()).isNull();
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void missingApiPathIsReportedAsNotFound(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withStatus(HttpStatus.NOT_FOUND).body("{\"path\":\"" + SECRET + "\"}"));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.NOT_FOUND);
        assertThat(thrown.getMessage()).contains("DHIS2_BASE_URL");
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void loginRedirectIsNotTreatedAsSuccess(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withStatus(HttpStatus.FOUND)
                        .header(HttpHeaders.LOCATION, "https://dhis.example/hmis/dhis-web-commons/security/login.action"));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.REDIRECTED);
        assertThat(thrown.getMessage()).doesNotContain("login.action");
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void otherHttpFailuresDoNotExposeTheResponse(CapturedOutput output) {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withStatus(HttpStatus.INTERNAL_SERVER_ERROR).body(SECRET));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.UNSUCCESSFUL);
        assertThat(thrown.getMessage()).isEqualTo("DHIS2 returned an unsuccessful response");
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void timeoutDoesNotExposeTransportDetails(CapturedOutput output) throws Exception {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withException(new HttpTimeoutException("timed out reading " + SECRET)));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.TIMEOUT);
        assertThat(thrown.getMessage()).isEqualTo("DHIS2 did not respond before the timeout");
        assertThat(thrown.getCause()).isNull();
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertThat(output).contains("TIMEOUT").contains("HttpTimeoutException");
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void dnsAndConnectionFailuresAreUnreachable(CapturedOutput output) throws Exception {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withException(new UnknownHostException(SECRET)));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.UNREACHABLE);
        assertThat(thrown.getMessage()).isEqualTo("Unable to reach DHIS2");
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertThat(output).contains("UnknownHostException");
        assertNoSecrets(output, harness.authorization);

        Harness refused = harness();
        refused.server.expect(requestTo(CURRENT_USER))
                .andRespond(withException(new ConnectException("Connection refused " + SECRET)));
        Dhis2ClientException connectionFailure = assertCheckFails(refused);
        assertThat(connectionFailure.kind()).isEqualTo(Dhis2ClientException.Kind.UNREACHABLE);
        assertThat(connectionFailure.toString()).doesNotContain(SECRET);
        assertThat(output).contains("ConnectException");
        assertNoSecrets(output, refused.authorization);
    }

    @Test
    void tlsFailuresStayDistinctFromGenericNetworkErrors(CapturedOutput output) throws Exception {
        Harness harness = harness();
        harness.server.expect(requestTo(CURRENT_USER))
                .andRespond(withException(new SSLHandshakeException(SECRET)));

        Dhis2ClientException thrown = assertCheckFails(harness);

        assertThat(thrown.kind()).isEqualTo(Dhis2ClientException.Kind.TLS);
        assertThat(thrown.getMessage()).isEqualTo("Unable to establish a trusted TLS connection to DHIS2");
        assertThat(thrown.toString()).doesNotContain(SECRET);
        assertThat(output).contains("SSLHandshakeException");
        assertNoSecrets(output, harness.authorization);
    }

    @Test
    void wrappedHttpAndTransportErrorsDropResponseText() {
        RestClientResponseException httpFailure = new RestClientResponseException(
                "401 Unauthorized: " + SECRET,
                HttpStatus.UNAUTHORIZED,
                "Unauthorized",
                null,
                ("{\"password\":\"" + SECRET + "\"}").getBytes(StandardCharsets.UTF_8),
                StandardCharsets.UTF_8);
        Dhis2ClientException sanitized = Dhis2ClientException.from(httpFailure);
        assertThat(sanitized.kind()).isEqualTo(Dhis2ClientException.Kind.UNAUTHORIZED);
        assertThat(sanitized.getCause()).isNull();
        assertThat(sanitized.toString()).doesNotContain(SECRET);
        assertThat(sanitized.getMessage()).doesNotContain(SECRET);

        Dhis2ClientException transport = Dhis2ClientException.from(
                new IllegalStateException("Authorization: Basic " + SECRET));
        assertThat(transport.kind()).isEqualTo(Dhis2ClientException.Kind.UNREACHABLE);
        assertThat(transport.toString()).doesNotContain(SECRET);
        assertThat(transport.getMessage()).doesNotContain("Authorization");
    }

    private static Dhis2ClientException assertCheckFails(Harness harness) {
        Throwable thrown = catchThrowable(harness.client::verifyAuthentication);
        assertThat(thrown).isInstanceOf(Dhis2ClientException.class);
        harness.server.verify();
        return (Dhis2ClientException) thrown;
    }

    private static void assertNoSecrets(CapturedOutput output, String authorization) {
        assertThat(output).doesNotContain(SECRET);
        assertThat(output).doesNotContain("test-password");
        assertThat(output).doesNotContain("Authorization");
        assertThat(output).doesNotContain(authorization);
        assertThat(output).doesNotContain(authorization.substring("Basic ".length()));
    }

    private static Harness harness() {
        Dhis2Properties properties = new Dhis2Properties(
                URI.create("https://dhis.example/hmis"),
                "test-user",
                "test-password",
                Duration.ofSeconds(2),
                Duration.ofSeconds(2));
        HttpHeaders headers = new HttpHeaders();
        headers.setBasicAuth(properties.username(), properties.password());
        String authorization = headers.getFirst(HttpHeaders.AUTHORIZATION);
        assertThat(authorization).startsWith("Basic ");
        assertThat(authorization).doesNotContain("test-password");
        String decoded = new String(Base64.getDecoder().decode(authorization.substring("Basic ".length())),
                StandardCharsets.ISO_8859_1);
        if (!decoded.equals("test-user:test-password")) {
            decoded = new String(Base64.getDecoder().decode(authorization.substring("Basic ".length())),
                    StandardCharsets.UTF_8);
        }
        assertThat(decoded).isEqualTo("test-user:test-password");

        RestClient.Builder builder = RestClient.builder();
        MockRestServiceServer server = MockRestServiceServer.bindTo(builder).build();
        RestClient restClient = Dhis2ClientConfig.buildRestClient(properties, builder);
        Dhis2Client client = new Dhis2Client(restClient, properties);
        return new Harness(server, client, new Dhis2CheckController(client), authorization);
    }

    private record Harness(
            MockRestServiceServer server,
            Dhis2Client client,
            Dhis2CheckController controller,
            String authorization) {
    }
}
