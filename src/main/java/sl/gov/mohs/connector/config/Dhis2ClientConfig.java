package sl.gov.mohs.connector.config;

import java.net.http.HttpClient;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpHeaders;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration
public class Dhis2ClientConfig {
    public static final String USER_AGENT = "dhis2-emr-connector";

    @Bean
    RestClient dhis2RestClient(Dhis2Properties properties) {
        properties.validate();
        return buildRestClient(properties, RestClient.builder().requestFactory(requestFactory(properties)));
    }

    public static RestClient buildRestClient(Dhis2Properties properties, RestClient.Builder builder) {
        properties.validate();
        return builder
                .defaultHeaders(headers -> headers.setBasicAuth(properties.username(), properties.password()))
                .defaultHeader(HttpHeaders.USER_AGENT, USER_AGENT)
                .build();
    }

    public static JdkClientHttpRequestFactory requestFactory(Dhis2Properties properties) {
        HttpClient httpClient = HttpClient.newBuilder()
                .connectTimeout(properties.connectTimeout())
                // DHIS2 sends unauthenticated API calls to the HTML login page with a 302.
                // Following that redirect can look like a successful connection. TLS uses the
                // default JVM trust store; certificate checks stay enabled.
                .followRedirects(HttpClient.Redirect.NEVER)
                .build();
        JdkClientHttpRequestFactory factory = new JdkClientHttpRequestFactory(httpClient);
        factory.setReadTimeout(properties.readTimeout());
        return factory;
    }
}
