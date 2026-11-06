
# Configure Java 21
$env:JAVA_HOME = "C:\Program Files\Java\jdk-21.0.12"
$env:Path = "$env:JAVA_HOME\bin;$env:Path"

# DHIS2 configuration
$env:DHIS2_BASE_URL = "https://sl.dhis2.org/hmis23"
$env:DHIS2_USERNAME = "madimaliaka"

# Request password securely
$securePassword = Read-Host "Madimaliaka@001" -AsSecureString
$env:DHIS2_PASSWORD = [System.Net.NetworkCredential]::new("", $securePassword).Password

# Start connector
mvn spring-boot:run
