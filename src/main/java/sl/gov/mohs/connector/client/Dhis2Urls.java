package sl.gov.mohs.connector.client;

import java.net.URI;
import java.net.URISyntaxException;

public final class Dhis2Urls {
    private Dhis2Urls() {
    }

    public static URI currentUser(URI baseUrl) {
        if (baseUrl == null || baseUrl.getHost() == null || baseUrl.getHost().isBlank()) {
            throw new IllegalStateException("DHIS2 base URL is invalid");
        }
        String prefix = baseUrl.getRawPath() == null ? "" : baseUrl.getRawPath().replaceAll("/+$", "");
        try {
            return new URI(baseUrl.getScheme(), null, baseUrl.getHost(), baseUrl.getPort(),
                    prefix + "/api/me", null, null);
        } catch (URISyntaxException ex) {
            throw new IllegalStateException("DHIS2 base URL is invalid");
        }
    }
}
