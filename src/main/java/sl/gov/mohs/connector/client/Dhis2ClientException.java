package sl.gov.mohs.connector.client;

import java.net.http.HttpConnectTimeoutException;
import java.net.http.HttpTimeoutException;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import javax.net.ssl.SSLException;
import org.springframework.web.client.RestClientResponseException;

public final class Dhis2ClientException extends RuntimeException {
    public enum Kind {
        UNAUTHORIZED,
        FORBIDDEN,
        NOT_FOUND,
        REDIRECTED,
        UNSUCCESSFUL,
        TIMEOUT,
        TLS,
        UNREACHABLE
    }

    private final Kind kind;

    private Dhis2ClientException(Kind kind, String message) {
        super(message);
        this.kind = kind;
    }

    public Kind kind() {
        return kind;
    }

    public static Dhis2ClientException forHttpStatus(int status) {
        return switch (status) {
            case 401 -> failure(Kind.UNAUTHORIZED, "DHIS2 rejected the configured credentials");
            case 403 -> failure(Kind.FORBIDDEN,
                    "The DHIS2 account does not have permission to access this API");
            case 404 -> failure(Kind.NOT_FOUND,
                    "DHIS2 could not find the authentication endpoint. Check DHIS2_BASE_URL");
            case 301, 302, 303, 307, 308 -> failure(Kind.REDIRECTED,
                    "DHIS2 redirected the connection check. Authentication did not succeed");
            default -> failure(Kind.UNSUCCESSFUL, "DHIS2 returned an unsuccessful response");
        };
    }

    public static Dhis2ClientException forTransport(Throwable failure) {
        if (causedBy(failure, HttpTimeoutException.class)
                || causedBy(failure, HttpConnectTimeoutException.class)
                || causedByTimeoutType(failure)) {
            return failure(Kind.TIMEOUT, "DHIS2 did not respond before the timeout");
        }
        if (causedBy(failure, SSLException.class)) {
            return failure(Kind.TLS, "Unable to establish a trusted TLS connection to DHIS2");
        }
        return failure(Kind.UNREACHABLE, "Unable to reach DHIS2");
    }

    public static Dhis2ClientException from(Throwable failure) {
        Throwable current = failure;
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        RestClientResponseException httpFailure = null;
        while (current != null && seen.add(current)) {
            if (current instanceof Dhis2ClientException dhis2Failure) {
                return dhis2Failure;
            }
            if (httpFailure == null && current instanceof RestClientResponseException responseFailure) {
                httpFailure = responseFailure;
            }
            current = current.getCause();
        }
        if (httpFailure != null) {
            return forHttpStatus(httpFailure.getStatusCode().value());
        }
        return forTransport(failure);
    }

    private static Dhis2ClientException failure(Kind kind, String message) {
        return new Dhis2ClientException(kind, message);
    }

    private static boolean causedBy(Throwable failure, Class<? extends Throwable> type) {
        Throwable current = failure;
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        while (current != null && seen.add(current)) {
            if (type.isInstance(current)) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }

    private static boolean causedByTimeoutType(Throwable failure) {
        Throwable current = failure;
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        while (current != null && seen.add(current)) {
            String name = current.getClass().getSimpleName();
            if (name.contains("Timeout")) {
                return true;
            }
            current = current.getCause();
        }
        return false;
    }
}
