sc stop "Sophos MCS Agent"
sc stop "Sophos MCS Client"

sc stop "Sophos AutoUpdate Service"
sc stop "Sophos Web Control Service"
sc stop "swi_filter"
sc stop "swi_service"


sc delete "Sophos MCS Agent"
sc delete "Sophos MCS Client"

sc delete "Sophos AutoUpdate Service"
sc delete "Sophos Web Control Service"
sc delete "swi_filter"
sc delete "swi_service"

rd /s /q "C:\Program Files (x86)\sophos\"
