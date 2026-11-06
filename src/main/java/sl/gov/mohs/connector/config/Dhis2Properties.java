package sl.gov.mohs.connector.config;

import java.net.URI;
import java.time.Duration;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

@Validated
@ConfigurationProperties(prefix = "dhis2")
public record Dhis2Properties(
        @NotNull(message = "DHIS2 base URL must be set") URI baseUrl,
        @NotBlank(message = "DHIS2 username must be set") String username,
        @NotBlank(message = "DHIS2 password must be set") String password,
        @NotNull(message = "DHIS2 connect timeout must be set") Duration connectTimeout,
        @NotNull(message = "DHIS2 read timeout must be set") Duration readTimeout
) {
    public void validate() {
        if (baseUrl == null
                || baseUrl.getHost() == null
                || baseUrl.getHost().isBlank()
                || !"https".equalsIgnoreCase(baseUrl.getScheme())) {
            throw new IllegalStateException("DHIS2 base URL must be an absolute HTTPS URL");
        }
        if (baseUrl.getUserInfo() != null) {
            throw new IllegalStateException("DHIS2 base URL must not contain credentials");
        }
        if (baseUrl.getRawQuery() != null || baseUrl.getFragment() != null) {
            throw new IllegalStateException("DHIS2 base URL must not contain a query or fragment");
        }
        if (username == null || username.isBlank()) {
            throw new IllegalStateException("DHIS2 username must be set");
        }
        if (password == null || password.isBlank()) {
            throw new IllegalStateException("DHIS2 password must be set");
        }
        if (username.indexOf(':') >= 0 || containsControl(username) || containsControl(password)) {
            throw new IllegalStateException("DHIS2 credentials contain invalid characters");
        }
        if (!isPositive(connectTimeout) || !isPositive(readTimeout)) {
            throw new IllegalStateException("DHIS2 connect and read timeouts must be positive");
        }
    }

    @Override
    public String toString() {
        return "Dhis2Properties[baseUrl=" + redactedBaseUrl()
                + ", username=" + username
                + ", password=****, connectTimeout=" + connectTimeout
                + ", readTimeout=" + readTimeout + "]";
    }

    private String redactedBaseUrl() {
        if (baseUrl == null) {
            return "null";
        }
        StringBuilder builder = new StringBuilder();
        if (baseUrl.getScheme() != null) {
            builder.append(baseUrl.getScheme()).append("://");
        }
        if (baseUrl.getUserInfo() != null) {
            builder.append("***@");
        }
        if (baseUrl.getHost() != null) {
            builder.append(baseUrl.getHost());
        }
        if (baseUrl.getPort() >= 0) {
            builder.append(':').append(baseUrl.getPort());
        }
        if (baseUrl.getRawPath() != null) {
            builder.append(baseUrl.getRawPath());
        }
        return builder.toString();
    }

    private static boolean isPositive(Duration duration) {
        return duration != null && !duration.isZero() && !duration.isNegative();
    }

    private static boolean containsControl(String value) {
        for (int i = 0; i < value.length(); i++) {
            char character = value.charAt(i);
            if (character <= 0x1F || character == 0x7F) {
                return true;
            }
        }
        return false;
    }
}
