package sl.gov.mohs.connector.controller;

import static org.mockito.Mockito.doThrow;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import java.net.UnknownHostException;
import java.net.http.HttpTimeoutException;
import javax.net.ssl.SSLHandshakeException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.test.json.JsonCompareMode;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import sl.gov.mohs.connector.client.Dhis2Client;
import sl.gov.mohs.connector.client.Dhis2ClientException;

import static org.mockito.Mockito.mock;

import java.util.stream.Stream;

@ExtendWith(OutputCaptureExtension.class)
class Dhis2CheckControllerTest {
    private static final String SECRET = "super-secret-value";

    private Dhis2Client dhis2Client;
    private MockMvc mockMvc;

    @BeforeEach
    void setUp() {
        dhis2Client = mock(Dhis2Client.class);
        mockMvc = MockMvcBuilders.standaloneSetup(new Dhis2CheckController(dhis2Client)).build();
    }

    @Test
    void successfulCheckReturnsOnlyTheConnectionStatus() throws Exception {
        mockMvc.perform(get("/internal/dhis2/check"))
                .andExpect(status().isOk())
                .andExpect(header().string(HttpHeaders.CACHE_CONTROL, "no-store"))
                .andExpect(content().json(
                        "{\"status\":\"connected\",\"message\":\"DHIS2 authentication succeeded\"}",
                        JsonCompareMode.STRICT));
    }

    @ParameterizedTest
    @MethodSource("upstreamErrors")
    void upstreamFailuresUseSafeMessages(Dhis2ClientException failure, int status, String message) throws Exception {
        doThrow(failure).when(dhis2Client).verifyAuthentication();

        mockMvc.perform(get("/internal/dhis2/check"))
                .andExpect(status().is(status))
                .andExpect(jsonPath("$.status").value("error"))
                .andExpect(jsonPath("$.message").value(message))
                .andExpect(content().string(org.hamcrest.Matchers.not(org.hamcrest.Matchers.containsString(SECRET))))
                .andExpect(content().string(org.hamcrest.Matchers.not(
                        org.hamcrest.Matchers.containsString("Authorization"))));
    }

    @Test
    void unexpectedErrorsDoNotExposeExceptionText(CapturedOutput output) throws Exception {
        doThrow(new IllegalStateException("Authorization: Basic " + SECRET))
                .when(dhis2Client).verifyAuthentication();

        mockMvc.perform(get("/internal/dhis2/check"))
                .andExpect(status().isBadGateway())
                .andExpect(content().json(
                        "{\"status\":\"error\",\"message\":\"Unable to complete the DHIS2 connection check\"}",
                        JsonCompareMode.STRICT));

        assertThatNoSecrets(output);
    }

    private static void assertThatNoSecrets(CapturedOutput output) {
        org.assertj.core.api.Assertions.assertThat(output).doesNotContain(SECRET);
        org.assertj.core.api.Assertions.assertThat(output).doesNotContain("Authorization");
        org.assertj.core.api.Assertions.assertThat(output).doesNotContain("Basic ");
    }

    static Stream<Arguments> upstreamErrors() {
        return Stream.of(
                Arguments.of(Dhis2ClientException.forHttpStatus(401), HttpStatus.BAD_GATEWAY.value(),
                        "DHIS2 rejected the configured credentials"),
                Arguments.of(Dhis2ClientException.forHttpStatus(403), HttpStatus.BAD_GATEWAY.value(),
                        "The DHIS2 account does not have permission to access this API"),
                Arguments.of(Dhis2ClientException.forHttpStatus(404), HttpStatus.BAD_GATEWAY.value(),
                        "DHIS2 could not find the authentication endpoint. Check DHIS2_BASE_URL"),
                Arguments.of(Dhis2ClientException.forHttpStatus(302), HttpStatus.BAD_GATEWAY.value(),
                        "DHIS2 redirected the connection check. Authentication did not succeed"),
                Arguments.of(Dhis2ClientException.forHttpStatus(500), HttpStatus.BAD_GATEWAY.value(),
                        "DHIS2 returned an unsuccessful response"),
                Arguments.of(Dhis2ClientException.forTransport(new HttpTimeoutException(SECRET)),
                        HttpStatus.GATEWAY_TIMEOUT.value(),
                        "DHIS2 did not respond before the timeout"),
                Arguments.of(Dhis2ClientException.forTransport(new UnknownHostException(SECRET)),
                        HttpStatus.BAD_GATEWAY.value(),
                        "Unable to reach DHIS2"),
                Arguments.of(Dhis2ClientException.forTransport(new SSLHandshakeException(SECRET)),
                        HttpStatus.BAD_GATEWAY.value(),
                        "Unable to establish a trusted TLS connection to DHIS2"));
    }
}
