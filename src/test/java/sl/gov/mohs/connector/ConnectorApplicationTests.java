package sl.gov.mohs.connector;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import sl.gov.mohs.connector.client.Dhis2Client;

@SpringBootTest(properties = {
        "dhis2.base-url=https://dhis.example/hmis",
        "dhis2.username=test-user",
        "dhis2.password=test-password",
        "dhis2.connect-timeout=2s",
        "dhis2.read-timeout=2s"
})
class ConnectorApplicationTests {
    @Autowired
    private Dhis2Client dhis2Client;

    @Test
    void contextLoadsWithoutCallingDhis2() {
        assertThat(dhis2Client).isNotNull();
    }
}
