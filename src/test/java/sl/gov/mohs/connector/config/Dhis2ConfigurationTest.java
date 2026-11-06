package sl.gov.mohs.connector.config;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.catchThrowable;

import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.URI;
import java.time.Duration;
import java.util.Collections;
import java.util.HashMap;
import java.util.IdentityHashMap;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.Timeout;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.boot.Banner;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.WebApplicationType;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.web.embedded.tomcat.TomcatServletWebServerFactory;
import org.springframework.core.Ordered;
import org.springframework.core.annotation.Order;
import org.springframework.core.env.MapPropertySource;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import sl.gov.mohs.connector.ConnectorApplication;
import sl.gov.mohs.connector.client.Dhis2ClientException;

@ExtendWith(OutputCaptureExtension.class)
class Dhis2ConfigurationTest {
    private static final String SECRET = "super-secret-value";

    @Test
    void toStringRedactsPasswordsAndCredentialsEmbeddedInTheUrl() {
        Dhis2Properties properties = new Dhis2Properties(
                URI.create("https://svc:" + SECRET + "@dhis.example/hmis?access_token=" + SECRET),
                "svc-account",
                SECRET,
                Duration.ofSeconds(5),
                Duration.ofSeconds(20));

        String text = properties.toString();

        assertThat(text).contains("svc-account").contains("password=****");
        assertThat(text).doesNotContain(SECRET);
        assertThat(text).doesNotContain("access_token");
    }

    @Test
    void rejectsUnsafeConfigurationBeforeCreatingAClient() {
        assertThatThrownBy(() -> new Dhis2ClientConfig().dhis2RestClient(properties(
                "http://dhis.example/hmis", "svc", SECRET)))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("DHIS2 base URL must be an absolute HTTPS URL");

        Throwable credentialsInUrl = catchThrowable(() -> new Dhis2ClientConfig().dhis2RestClient(properties(
                "https://svc:" + SECRET + "@dhis.example/hmis", "svc", "other-password")));
        assertThat(credentialsInUrl).isInstanceOf(IllegalStateException.class);
        assertThat(credentialsInUrl.toString()).doesNotContain(SECRET);

        assertThatThrownBy(() -> properties("https://dhis.example/hmis", "svc:user", SECRET).validate())
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("DHIS2 credentials contain invalid characters");

        assertThatThrownBy(() -> new Dhis2Properties(
                URI.create("https://dhis.example/hmis"),
                "svc",
                SECRET,
                Duration.ZERO,
                Duration.ofSeconds(5)).validate())
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("DHIS2 connect and read timeouts must be positive");
    }

    @Test
    void diagnosticServerBindsToLoopbackLast() throws Exception {
        Order order = LocalServerConfig.class.getDeclaredMethod("loopbackOnly").getAnnotation(Order.class);
        assertThat(order.value()).isEqualTo(Ordered.LOWEST_PRECEDENCE);

        TomcatServletWebServerFactory factory = new TomcatServletWebServerFactory();
        factory.setAddress(InetAddress.getByName("0.0.0.0"));
        new LocalServerConfig().loopbackOnly().customize(factory);

        assertThat(factory.getAddress().isLoopbackAddress()).isTrue();
    }

    @Test
    @Timeout(15)
    void readTimeoutIsAppliedByTheRequestFactory() throws Exception {
        Dhis2Properties properties = new Dhis2Properties(
                URI.create("https://dhis.example/hmis"),
                "svc",
                SECRET,
                Duration.ofMillis(500),
                Duration.ofMillis(500));
        JdkClientHttpRequestFactory factory = Dhis2ClientConfig.requestFactory(properties);
        try (ServerSocket socket = new ServerSocket()) {
            socket.bind(new InetSocketAddress(InetAddress.getLoopbackAddress(), 0), 1);
            Thread holder = new Thread(() -> {
                try (var accepted = socket.accept()) {
                    accepted.getInputStream().readNBytes(2048);
                    Thread.sleep(20_000);
                } catch (Exception ignored) {
                    // The client closes the socket when its read timeout expires.
                }
            });
            holder.setDaemon(true);
            holder.start();
            RestClient client = RestClient.builder().requestFactory(factory).build();
            long started = System.nanoTime();
            Throwable thrown = catchThrowable(() -> client.get()
                    .uri("http://127.0.0.1:" + socket.getLocalPort() + "/api/me")
                    .retrieve()
                    .toBodilessEntity());
            long elapsedMs = Duration.ofNanos(System.nanoTime() - started).toMillis();
            holder.interrupt();

            assertThat(thrown).isInstanceOf(ResourceAccessException.class);
            assertThat(elapsedMs).isLessThan(5_000);
            Dhis2ClientException mapped = Dhis2ClientException.forTransport(thrown);
            assertThat(mapped.kind()).isEqualTo(Dhis2ClientException.Kind.TIMEOUT);
            assertThat(mapped.getCause()).isNull();
            assertThat(mapped.toString()).doesNotContain(SECRET);
        }
    }

    @Test
    void applicationDoesNotStartWhenCredentialsAreMissing(CapturedOutput output) {
        Throwable missingUsername = start(Map.of(
                "dhis2.base-url", "https://dhis.example/hmis",
                "dhis2.username", " ",
                "dhis2.password", SECRET,
                "dhis2.connect-timeout", "5s",
                "dhis2.read-timeout", "20s"));
        assertThat(missingUsername).isNotNull();
        assertThat(throwableText(missingUsername)).contains("DHIS2 username must be set");
        assertThat(throwableText(missingUsername) + output).doesNotContain(SECRET);
        assertThat(output).doesNotContain("Authorization");

        Throwable missingPassword = start(Map.of(
                "dhis2.base-url", "https://dhis.example/hmis",
                "dhis2.username", "svc-account",
                "dhis2.password", " ",
                "dhis2.connect-timeout", "5s",
                "dhis2.read-timeout", "20s"));
        assertThat(throwableText(missingPassword)).contains("DHIS2 password must be set");
        assertThat(throwableText(missingPassword) + output).doesNotContain("svc-account:").doesNotContain(SECRET);
    }

    @Test
    void applicationDoesNotStartForAnHttpBaseUrl(CapturedOutput output) {
        Throwable thrown = start(Map.of(
                "dhis2.base-url", "http://dhis.example/hmis",
                "dhis2.username", "svc-account",
                "dhis2.password", SECRET,
                "dhis2.connect-timeout", "5s",
                "dhis2.read-timeout", "20s"));

        assertThat(throwableText(thrown)).contains("DHIS2 base URL must be an absolute HTTPS URL");
        assertThat(throwableText(thrown) + output).doesNotContain(SECRET);
        assertThat(output).doesNotContain("Authorization");
    }

    private static Throwable start(Map<String, String> overrides) {
        return catchThrowable(() -> {
            SpringApplication application = new SpringApplication(ConnectorApplication.class);
            application.setWebApplicationType(WebApplicationType.NONE);
            application.setBannerMode(Banner.Mode.OFF);
            application.setLogStartupInfo(false);
            application.setRegisterShutdownHook(false);
            Map<String, Object> values = new HashMap<>();
            values.putAll(overrides);
            application.addInitializers(context -> context.getEnvironment().getPropertySources()
                    .addFirst(new MapPropertySource("test-overrides", values)));
            try (var context = application.run()) {
                context.start();
            }
        });
    }

    private static String throwableText(Throwable throwable) {
        StringBuilder builder = new StringBuilder();
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        while (throwable != null && seen.add(throwable)) {
            builder.append(throwable).append('\n');
            throwable = throwable.getCause();
        }
        return builder.toString();
    }

    private static Dhis2Properties properties(String baseUrl, String username, String password) {
        return new Dhis2Properties(URI.create(baseUrl), username, password,
                Duration.ofSeconds(5), Duration.ofSeconds(20));
    }
}
