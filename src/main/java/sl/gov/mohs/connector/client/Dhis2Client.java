package sl.gov.mohs.connector.client;

import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import sl.gov.mohs.connector.config.Dhis2Properties;

@Component
public class Dhis2Client {
    private static final Logger log = LoggerFactory.getLogger(Dhis2Client.class);
    private static final int MAX_DISCARD_BYTES = 65_536;

    private final RestClient restClient;
    private final URI currentUserUri;

    public Dhis2Client(RestClient dhis2RestClient, Dhis2Properties properties) {
        properties.validate();
        this.restClient = dhis2RestClient;
        this.currentUserUri = Dhis2Urls.currentUser(properties.baseUrl());
        log.info("DHIS2 connector is configured for host {}", properties.baseUrl().getHost());
    }

    public void verifyAuthentication() {
        try {
            restClient.get()
                    .uri(currentUserUri)
                    .accept(MediaType.APPLICATION_JSON)
                    .exchange((request, response) -> {
                        discard(response.getBody());
                        int status = response.getStatusCode().value();
                        if (status >= 200 && status < 300) {
                            return Boolean.TRUE;
                        }
                        throw Dhis2ClientException.forHttpStatus(status);
                    });
            log.info("DHIS2 authentication check succeeded");
        } catch (RuntimeException ex) {
            Dhis2ClientException safe = Dhis2ClientException.from(ex);
            log.warn("DHIS2 authentication check failed ({}; cause={})", safe.kind(), rootSimpleName(ex));
            throw safe;
        }
    }

    private static void discard(InputStream body) throws IOException {
        if (body == null) {
            return;
        }
        byte[] buffer = new byte[4096];
        int total = 0;
        int read;
        while (total < MAX_DISCARD_BYTES && (read = body.read(buffer)) != -1) {
            total += read;
        }
    }

    private static String rootSimpleName(Throwable failure) {
        Throwable current = failure;
        Throwable root = failure;
        Set<Throwable> seen = Collections.newSetFromMap(new IdentityHashMap<>());
        while (current != null && seen.add(current)) {
            root = current;
            current = current.getCause();
        }
        return root == null ? "unknown" : root.getClass().getSimpleName();
    }
}
