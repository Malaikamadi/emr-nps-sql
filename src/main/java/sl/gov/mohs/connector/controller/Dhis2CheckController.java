package sl.gov.mohs.connector.controller;

import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.CacheControl;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;
import sl.gov.mohs.connector.client.Dhis2Client;
import sl.gov.mohs.connector.client.Dhis2ClientException;

@RestController
@RequestMapping("/internal/dhis2")
public class Dhis2CheckController {
    private static final Logger log = LoggerFactory.getLogger(Dhis2CheckController.class);

    private final Dhis2Client dhis2Client;

    public Dhis2CheckController(Dhis2Client dhis2Client) {
        this.dhis2Client = dhis2Client;
    }

    @GetMapping(value = "/check", produces = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<Map<String, String>> checkConnection() {
        try {
            dhis2Client.verifyAuthentication();
            return json(HttpStatus.OK, "connected", "DHIS2 authentication succeeded");
        } catch (Dhis2ClientException ex) {
            return json(statusFor(ex.kind()), "error", ex.getMessage());
        } catch (RuntimeException ex) {
            log.warn("DHIS2 connection check failed unexpectedly ({})", ex.getClass().getSimpleName());
            return json(HttpStatus.BAD_GATEWAY, "error", "Unable to complete the DHIS2 connection check");
        }
    }

    private static HttpStatus statusFor(Dhis2ClientException.Kind kind) {
        if (kind == Dhis2ClientException.Kind.TIMEOUT) {
            return HttpStatus.GATEWAY_TIMEOUT;
        }
        return HttpStatus.BAD_GATEWAY;
    }

    private static ResponseEntity<Map<String, String>> json(HttpStatus status, String state, String message) {
        return ResponseEntity.status(status)
                .cacheControl(CacheControl.noStore())
                .body(Map.of("status", state, "message", message));
    }
}
