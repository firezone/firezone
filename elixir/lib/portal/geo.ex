defmodule Portal.Geo do
  @radius_of_earth_km 6371.0

  # ISO 3166-1 alpha-2
  # https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2
  @countries %{
    "LT" => %{common_name: "Lithuania", coordinates: {56.0, 24.0}},
    "GU" => %{common_name: "Guam", coordinates: {13.46666666, 144.78333333}},
    "BA" => %{common_name: "Bosnia and Herzegovina", coordinates: {44.0, 18.0}},
    "LI" => %{common_name: "Liechtenstein", coordinates: {47.26666666, 9.53333333}},
    "CZ" => %{common_name: "Czechia", coordinates: {49.75, 15.5}},
    "AD" => %{common_name: "Andorra", coordinates: {42.5, 1.5}},
    "MT" => %{common_name: "Malta", coordinates: {35.83333333, 14.58333333}},
    "MX" => %{common_name: "Mexico", coordinates: {23.0, -102.0}},
    "TH" => %{common_name: "Thailand", coordinates: {15.0, 100.0}},
    "EH" => %{common_name: "Western Sahara", coordinates: {24.5, -13.0}},
    "LR" => %{common_name: "Liberia", coordinates: {6.5, -9.5}},
    "HK" => %{common_name: "Hong Kong", coordinates: {22.25, 114.16666666}},
    "SZ" => %{common_name: "Eswatini", coordinates: {-26.5, 31.5}},
    "TD" => %{common_name: "Chad", coordinates: {15.0, 19.0}},
    "TR" => %{common_name: "Türkiye", coordinates: {39.0, 35.0}},
    "KG" => %{common_name: "Kyrgyzstan", coordinates: {41.0, 75.0}},
    "YE" => %{common_name: "Yemen", coordinates: {15.0, 48.0}},
    "SJ" => %{common_name: "Svalbard and Jan Mayen", coordinates: {78.0, 20.0}},
    "IN" => %{common_name: "India", coordinates: {20.0, 77.0}},
    "FO" => %{common_name: "Faroe Islands", coordinates: {62.0, -7.0}},
    "US" => %{common_name: "United States of America", coordinates: {38.0, -97.0}},
    "SD" => %{common_name: "Sudan", coordinates: {15.0, 30.0}},
    "IR" => %{common_name: "Iran", coordinates: {32.0, 53.0}},
    "CW" => %{common_name: "Curaçao", coordinates: {12.116667, -68.933333}},
    "SE" => %{common_name: "Sweden", coordinates: {62.0, 15.0}},
    "LK" => %{common_name: "Sri Lanka", coordinates: {7.0, 81.0}},
    "KH" => %{common_name: "Cambodia", coordinates: {13.0, 105.0}},
    "CN" => %{common_name: "China", coordinates: {35.0, 105.0}},
    "SA" => %{common_name: "Saudi Arabia", coordinates: {25.0, 45.0}},
    "IM" => %{common_name: "Isle of Man", coordinates: {54.25, -4.5}},
    "GY" => %{common_name: "Guyana", coordinates: {5.0, -59.0}},
    "ST" => %{common_name: "Sao Tome and Principe", coordinates: {1.0, 7.0}},
    "AL" => %{common_name: "Albania", coordinates: {41.0, 20.0}},
    "SO" => %{common_name: "Somalia", coordinates: {10.0, 49.0}},
    "BS" => %{common_name: "Bahamas", coordinates: {24.25, -76.0}},
    "GM" => %{common_name: "Gambia", coordinates: {13.46666666, -16.56666666}},
    "ES" => %{common_name: "Spain", coordinates: {40.0, -4.0}},
    "RW" => %{common_name: "Rwanda", coordinates: {-2.0, 30.0}},
    "EE" => %{common_name: "Estonia", coordinates: {59.0, 26.0}},
    "HN" => %{common_name: "Honduras", coordinates: {15.0, -86.5}},
    "MQ" => %{common_name: "Martinique", coordinates: {14.666667, -61.0}},
    "EG" => %{common_name: "Egypt", coordinates: {27.0, 30.0}},
    "GI" => %{common_name: "Gibraltar", coordinates: {36.13333333, -5.35}},
    "CC" => %{common_name: "Cocos (Keeling) Islands", coordinates: {-12.5, 96.83333333}},
    "MA" => %{common_name: "Morocco", coordinates: {32.0, -5.0}},
    "MC" => %{common_name: "Monaco", coordinates: {43.73333333, 7.4}},
    "DE" => %{common_name: "Germany", coordinates: {51.0, 9.0}},
    "YT" => %{common_name: "Mayotte", coordinates: {-12.83333333, 45.16666666}},
    "KI" => %{common_name: "Kiribati", coordinates: {1.41666666, 173.0}},
    "CU" => %{common_name: "Cuba", coordinates: {21.5, -80.0}},
    "GL" => %{common_name: "Greenland", coordinates: {72.0, -40.0}},
    "CH" => %{common_name: "Switzerland", coordinates: {47.0, 8.0}},
    "BY" => %{common_name: "Belarus", coordinates: {53.0, 28.0}},
    "NF" => %{common_name: "Norfolk Island", coordinates: {-29.03333333, 167.95}},
    "SS" => %{common_name: "South Sudan", coordinates: {7.0, 30.0}},
    "GR" => %{common_name: "Greece", coordinates: {39.0, 22.0}},
    "DO" => %{common_name: "Dominican Republic", coordinates: {19.0, -70.66666666}},
    "CI" => %{common_name: "Côte d'Ivoire", coordinates: {8.0, -5.0}},
    "BQ" => %{common_name: "Bonaire", coordinates: {12.15, -68.266667}},
    "KN" => %{common_name: "Saint Kitts and Nevis", coordinates: {17.33333333, -62.75}},
    "KE" => %{common_name: "Kenya", coordinates: {1.0, 38.0}},
    "PL" => %{common_name: "Poland", coordinates: {52.0, 20.0}},
    "RO" => %{common_name: "Romania", coordinates: {46.0, 25.0}},
    "BI" => %{common_name: "Burundi", coordinates: {-3.5, 30.0}},
    "BO" => %{common_name: "Bolivia", coordinates: {-17.0, -65.0}},
    "SX" => %{common_name: "Sint Maarten (Dutch part)", coordinates: {18.033333, -63.05}},
    "CY" => %{common_name: "Cyprus", coordinates: {35.0, 33.0}},
    "CL" => %{common_name: "Chile", coordinates: {-30.0, -71.0}},
    "TL" => %{common_name: "Timor-Leste", coordinates: {-8.83333333, 125.91666666}},
    "AU" => %{common_name: "Australia", coordinates: {-27.0, 133.0}},
    "KP" => %{common_name: "North Korea", coordinates: {40.0, 127.0}},
    "WF" => %{common_name: "Wallis and Futuna", coordinates: {-13.3, -176.2}},
    "MY" => %{common_name: "Malaysia", coordinates: {2.5, 112.5}},
    "MV" => %{common_name: "Maldives", coordinates: {3.25, 73.0}},
    "TG" => %{common_name: "Togo", coordinates: {8.0, 1.16666666}},
    "FI" => %{common_name: "Finland", coordinates: {64.0, 26.0}},
    "MP" => %{common_name: "Northern Mariana Islands", coordinates: {15.2, 145.75}},
    "RS" => %{common_name: "Serbia", coordinates: {44.0, 21.0}},
    "NA" => %{common_name: "Namibia", coordinates: {-22.0, 17.0}},
    "SI" => %{common_name: "Slovenia", coordinates: {46.11666666, 14.81666666}},
    "GD" => %{common_name: "Grenada", coordinates: {12.11666666, -61.66666666}},
    "VU" => %{common_name: "Vanuatu", coordinates: {-16.0, 167.0}},
    "GW" => %{common_name: "Guinea-Bissau", coordinates: {12.0, -15.0}},
    "GT" => %{common_name: "Guatemala", coordinates: {15.5, -90.25}},
    "IQ" => %{common_name: "Iraq", coordinates: {33.0, 44.0}},
    "BJ" => %{common_name: "Benin", coordinates: {9.5, 2.25}},
    "BZ" => %{common_name: "Belize", coordinates: {17.25, -88.75}},
    "GQ" => %{common_name: "Equatorial Guinea", coordinates: {2.0, 10.0}},
    "MN" => %{common_name: "Mongolia", coordinates: {46.0, 105.0}},
    "CX" => %{common_name: "Christmas Island", coordinates: {-10.5, 105.66666666}},
    "MZ" => %{common_name: "Mozambique", coordinates: {-18.25, 35.0}},
    "JM" => %{common_name: "Jamaica", coordinates: {18.25, -77.5}},
    "UM" => %{
      common_name: "United States Minor Outlying Islands",
      coordinates: {13.9172255, -134.1859535}
    },
    "IE" => %{common_name: "Ireland", coordinates: {53.0, -8.0}},
    "CR" => %{common_name: "Costa Rica", coordinates: {10.0, -84.0}},
    "PM" => %{common_name: "Saint Pierre and Miquelon", coordinates: {46.83333333, -56.33333333}},
    "MD" => %{common_name: "Moldova", coordinates: {47.0, 29.0}},
    "PR" => %{common_name: "Puerto Rico", coordinates: {18.25, -66.5}},
    "MO" => %{common_name: "Macao", coordinates: {22.16666666, 113.55}},
    "TO" => %{common_name: "Tonga", coordinates: {-20.0, -175.0}},
    "AO" => %{common_name: "Angola", coordinates: {-12.5, 18.5}},
    "AQ" => %{common_name: "Antarctica", coordinates: {-74.65, 4.48}},
    "IT" => %{common_name: "Italy", coordinates: {42.83333333, 12.83333333}},
    "TV" => %{common_name: "Tuvalu", coordinates: {-8.0, 178.0}},
    "SH" => %{common_name: "Saint Helena", coordinates: {-15.95, -5.7}},
    "ME" => %{common_name: "Montenegro", coordinates: {42.5, 19.3}},
    "GB" => %{
      common_name: "United Kingdom of Great Britain and Northern Ireland",
      coordinates: {54.0, -2.0}
    },
    "FK" => %{common_name: "Falkland Islands (Malvinas)", coordinates: {-51.75, -59.0}},
    "NO" => %{common_name: "Norway", coordinates: {62.0, 10.0}},
    "DM" => %{common_name: "Dominica", coordinates: {15.41666666, -61.33333333}},
    "PE" => %{common_name: "Peru", coordinates: {-10.0, -76.0}},
    "NR" => %{common_name: "Nauru", coordinates: {-0.53333333, 166.91666666}},
    "MS" => %{common_name: "Montserrat", coordinates: {16.75, -62.2}},
    "PW" => %{common_name: "Palau", coordinates: {7.5, 134.5}},
    "KM" => %{common_name: "Comoros", coordinates: {-12.16666666, 44.25}},
    "AF" => %{common_name: "Afghanistan", coordinates: {33.0, 65.0}},
    "MM" => %{common_name: "Myanmar", coordinates: {22.0, 98.0}},
    "CK" => %{common_name: "Cook Islands", coordinates: {-21.23333333, -159.76666666}},
    "MU" => %{common_name: "Mauritius", coordinates: {-20.28333333, 57.55}},
    "BD" => %{common_name: "Bangladesh", coordinates: {24.0, 90.0}},
    "FJ" => %{common_name: "Fiji", coordinates: {-18.0, 175.0}},
    "UG" => %{common_name: "Uganda", coordinates: {1.0, 32.0}},
    "RU" => %{common_name: "Russia", coordinates: {60.0, 100.0}},
    "GN" => %{common_name: "Guinea", coordinates: {11.0, -10.0}},
    "BM" => %{common_name: "Bermuda", coordinates: {32.33333333, -64.75}},
    "JP" => %{common_name: "Japan", coordinates: {36.0, 138.0}},
    "TT" => %{common_name: "Trinidad and Tobago", coordinates: {11.0, -61.0}},
    "IS" => %{common_name: "Iceland", coordinates: {65.0, -18.0}},
    "FM" => %{common_name: "Micronesia", coordinates: {6.91666666, 158.25}},
    "KY" => %{common_name: "Cayman Islands", coordinates: {19.5, -80.5}},
    "MH" => %{common_name: "Marshall Islands", coordinates: {9.0, 168.0}},
    "UA" => %{common_name: "Ukraine", coordinates: {49.0, 32.0}},
    "NC" => %{common_name: "New Caledonia", coordinates: {-21.5, 165.5}},
    "MW" => %{common_name: "Malawi", coordinates: {-13.5, 34.0}},
    "TF" => %{common_name: "French Southern Territories", coordinates: {-49.25, 69.167}},
    "LS" => %{common_name: "Lesotho", coordinates: {-29.5, 28.5}},
    "IO" => %{common_name: "British Indian Ocean Territory", coordinates: {-6.0, 71.5}},
    "SN" => %{common_name: "Senegal", coordinates: {14.0, -14.0}},
    "DZ" => %{common_name: "Algeria", coordinates: {28.0, 3.0}},
    "AW" => %{common_name: "Aruba", coordinates: {12.5, -69.96666666}},
    "GS" => %{
      common_name: "South Georgia and the South Sandwich Islands",
      coordinates: {-54.5, -37.0}
    },
    "SM" => %{common_name: "San Marino", coordinates: {43.76666666, 12.41666666}},
    "PA" => %{common_name: "Panama", coordinates: {9.0, -80.0}},
    "JO" => %{common_name: "Jordan", coordinates: {31.0, 36.0}},
    "VE" => %{common_name: "Venezuela", coordinates: {8.0, -66.0}},
    "AE" => %{common_name: "United Arab Emirates", coordinates: {24.0, 54.0}},
    "TJ" => %{common_name: "Tajikistan", coordinates: {39.0, 71.0}},
    "BT" => %{common_name: "Bhutan", coordinates: {27.5, 90.5}},
    "TC" => %{common_name: "Turks and Caicos Islands", coordinates: {21.75, -71.58333333}},
    "NP" => %{common_name: "Nepal", coordinates: {28.0, 84.0}},
    "LB" => %{common_name: "Lebanon", coordinates: {33.83333333, 35.83333333}},
    "HU" => %{common_name: "Hungary", coordinates: {47.0, 20.0}},
    "LU" => %{common_name: "Luxembourg", coordinates: {49.75, 6.16666666}},
    "DK" => %{common_name: "Denmark", coordinates: {56.0, 10.0}},
    "BF" => %{common_name: "Burkina Faso", coordinates: {13.0, -2.0}},
    "VA" => %{common_name: "Holy See", coordinates: {41.9, 12.45}},
    "SK" => %{common_name: "Slovakia", coordinates: {48.66666666, 19.5}},
    "UZ" => %{common_name: "Uzbekistan", coordinates: {41.0, 64.0}},
    "NG" => %{common_name: "Nigeria", coordinates: {10.0, 8.0}},
    "AG" => %{common_name: "Antigua and Barbuda", coordinates: {17.05, -61.8}},
    "EC" => %{common_name: "Ecuador", coordinates: {-2.0, -77.5}},
    "SC" => %{common_name: "Seychelles", coordinates: {-4.58333333, 55.66666666}},
    "AR" => %{common_name: "Argentina", coordinates: {-34.0, -64.0}},
    "BW" => %{common_name: "Botswana", coordinates: {-22.0, 24.0}},
    "BE" => %{common_name: "Belgium", coordinates: {50.83333333, 4.0}},
    "TM" => %{common_name: "Turkmenistan", coordinates: {40.0, 60.0}},
    "VN" => %{common_name: "Vietnam", coordinates: {16.16666666, 107.83333333}},
    "PH" => %{common_name: "Philippines", coordinates: {13.0, 122.0}},
    "SG" => %{common_name: "Singapore", coordinates: {1.36666666, 103.8}},
    "TK" => %{common_name: "Tokelau", coordinates: {-9.0, -172.0}},
    "BV" => %{common_name: "Bouvet Island", coordinates: {-54.43333333, 3.4}},
    "MG" => %{common_name: "Madagascar", coordinates: {-20.0, 47.0}},
    "GP" => %{common_name: "Guadeloupe", coordinates: {16.25, -61.583333}},
    "ET" => %{common_name: "Ethiopia", coordinates: {8.0, 38.0}},
    "CM" => %{common_name: "Cameroon", coordinates: {6.0, 12.0}},
    "AX" => %{common_name: "Åland Islands", coordinates: {60.116667, 19.9}},
    "BL" => %{common_name: "Saint Barthélemy", coordinates: {18.5, -63.41666666}},
    "SY" => %{common_name: "Syria", coordinates: {35.0, 38.0}},
    "MR" => %{common_name: "Mauritania", coordinates: {20.0, -12.0}},
    "LY" => %{common_name: "Libya", coordinates: {25.0, 17.0}},
    "RE" => %{common_name: "Réunion", coordinates: {-21.15, 55.5}},
    "HM" => %{common_name: "Heard Island and McDonald Islands", coordinates: {-53.1, 72.51666666}},
    "VG" => %{common_name: "Virgin Islands (British)", coordinates: {18.431383, -64.62305}},
    "AZ" => %{common_name: "Azerbaijan", coordinates: {40.5, 47.5}},
    "CF" => %{common_name: "Central African Republic", coordinates: {7.0, 21.0}},
    "AT" => %{common_name: "Austria", coordinates: {47.33333333, 13.33333333}},
    "BH" => %{common_name: "Bahrain", coordinates: {26.0, 50.55}},
    "PT" => %{common_name: "Portugal", coordinates: {39.5, -8.0}},
    "TN" => %{common_name: "Tunisia", coordinates: {34.0, 9.0}},
    "TZ" => %{common_name: "Tanzania", coordinates: {-6.0, 35.0}},
    "ZA" => %{common_name: "South Africa", coordinates: {-29.0, 24.0}},
    "VC" => %{common_name: "Saint Vincent and the Grenadines", coordinates: {13.25, -61.2}},
    "PK" => %{common_name: "Pakistan", coordinates: {30.0, 70.0}},
    "PY" => %{common_name: "Paraguay", coordinates: {-23.0, -58.0}},
    "CD" => %{common_name: "Congo", coordinates: {0.0, 25.0}},
    "WS" => %{common_name: "Samoa", coordinates: {-13.58333333, -172.33333333}},
    "UY" => %{common_name: "Uruguay", coordinates: {-33.0, -56.0}},
    "SB" => %{common_name: "Solomon Islands", coordinates: {-8.0, 159.0}},
    "GE" => %{common_name: "Georgia", coordinates: {42.0, 43.5}},
    "GA" => %{common_name: "Gabon", coordinates: {-1.0, 11.75}},
    "HT" => %{common_name: "Haiti", coordinates: {19.0, -72.41666666}},
    "BG" => %{common_name: "Bulgaria", coordinates: {43.0, 25.0}},
    "OM" => %{common_name: "Oman", coordinates: {21.0, 57.0}},
    "CA" => %{common_name: "Canada", coordinates: {60.0, -95.0}},
    "KR" => %{common_name: "South Korea", coordinates: {37.0, 127.5}},
    "ER" => %{common_name: "Eritrea", coordinates: {15.0, 39.0}},
    "GF" => %{common_name: "French Guiana", coordinates: {4.0, -53.0}},
    "LV" => %{common_name: "Latvia", coordinates: {57.0, 25.0}},
    "AI" => %{common_name: "Anguilla", coordinates: {18.25, -63.16666666}},
    "ZW" => %{common_name: "Zimbabwe", coordinates: {-20.0, 30.0}},
    "BN" => %{common_name: "Brunei Darussalam", coordinates: {4.5, 114.66666666}},
    "SV" => %{common_name: "El Salvador", coordinates: {13.83333333, -88.91666666}},
    "NL" => %{common_name: "Netherlands", coordinates: {52.5, 5.75}},
    "PG" => %{common_name: "Papua New Guinea", coordinates: {-6.0, 147.0}},
    "GG" => %{common_name: "Guernsey", coordinates: {49.46666666, -2.58333333}},
    "TW" => %{common_name: "Taiwan", coordinates: {23.5, 121.0}},
    "CO" => %{common_name: "Colombia", coordinates: {4.0, -72.0}},
    "SR" => %{common_name: "Suriname", coordinates: {4.0, -56.0}},
    "HR" => %{common_name: "Croatia", coordinates: {45.16666666, 15.5}},
    "JE" => %{common_name: "Jersey", coordinates: {49.25, -2.16666666}},
    "LA" => %{common_name: "Laos", coordinates: {18.0, 105.0}},
    "KW" => %{common_name: "Kuwait", coordinates: {29.5, 45.75}},
    "PS" => %{common_name: "Palestine", coordinates: {31.9, 35.2}},
    "ZM" => %{common_name: "Zambia", coordinates: {-15.0, 30.0}},
    "NI" => %{common_name: "Nicaragua", coordinates: {13.0, -85.0}},
    "SL" => %{common_name: "Sierra Leone", coordinates: {8.5, -11.5}},
    "GH" => %{common_name: "Ghana", coordinates: {8.0, -2.0}},
    "IL" => %{common_name: "Israel", coordinates: {31.5, 34.75}},
    "AS" => %{common_name: "American Samoa", coordinates: {-14.33333333, -170.0}},
    "MF" => %{common_name: "Saint Martin (French part)", coordinates: {18.08333333, -63.95}},
    "NZ" => %{common_name: "New Zealand", coordinates: {-41.0, 174.0}},
    "BB" => %{common_name: "Barbados", coordinates: {13.16666666, -59.53333333}},
    "NU" => %{common_name: "Niue", coordinates: {-19.03333333, -169.86666666}},
    "DJ" => %{common_name: "Djibouti", coordinates: {11.5, 43.0}},
    "BR" => %{common_name: "Brazil", coordinates: {-10.0, -55.0}},
    "LC" => %{common_name: "Saint Lucia", coordinates: {13.88333333, -60.96666666}},
    "QA" => %{common_name: "Qatar", coordinates: {25.5, 51.25}},
    "ID" => %{common_name: "Indonesia", coordinates: {-5.0, 120.0}},
    "NE" => %{common_name: "Niger", coordinates: {16.0, 8.0}},
    "MK" => %{common_name: "North Macedonia", coordinates: {41.83333333, 22.0}},
    "FR" => %{common_name: "France", coordinates: {46.0, 2.0}},
    "PN" => %{common_name: "Pitcairn", coordinates: {-25.06666666, -130.1}},
    "AM" => %{common_name: "Armenia", coordinates: {40.0, 45.0}},
    "ML" => %{common_name: "Mali", coordinates: {17.0, -4.0}},
    "VI" => %{common_name: "Virgin Islands (U.S.)", coordinates: {18.34, -64.93}},
    "KZ" => %{common_name: "Kazakhstan", coordinates: {48.0, 68.0}},
    "CG" => %{common_name: "Congo", coordinates: {-1.0, 15.0}},
    "CV" => %{common_name: "Cabo Verde", coordinates: {16.0, -24.0}},
    "PF" => %{common_name: "French Polynesia", coordinates: {-15.0, -140.0}}
  }

  def distance({lat1, lon1}, {lat2, lon2}) do
    d_lat = degrees_to_radians(lat2 - lat1)
    d_lon = degrees_to_radians(lon2 - lon1)

    a =
      :math.sin(d_lat / 2) * :math.sin(d_lat / 2) +
        :math.cos(degrees_to_radians(lat1)) * :math.cos(degrees_to_radians(lat2)) *
          :math.sin(d_lon / 2) * :math.sin(d_lon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))

    @radius_of_earth_km * c
  end

  def location_from_headers(headers) do
    # Azure Front Door only provides country via {geo_country}.
    # GCP provides country, city, and coordinates.
    case get_header(headers, "x-azure-geo-country") do
      nil -> location_from_gcp_headers(headers)
      country -> {country, nil, maybe_put_default_coordinates(country, {nil, nil})}
    end
  end

  defp location_from_gcp_headers(headers) do
    region = get_header(headers, "x-geo-location-region")
    city = get_header(headers, "x-geo-location-city")

    coords =
      case get_header(headers, "x-geo-location-coordinates") do
        nil ->
          {nil, nil}

        coords ->
          [lat, lon] = String.split(coords, ",", parts: 2)
          {String.to_float(lat), String.to_float(lon)}
      end

    {region, city, maybe_put_default_coordinates(region, coords)}
  end

  defp degrees_to_radians(deg) do
    deg * :math.pi() / 180
  end

  defp maybe_put_default_coordinates(country_code, {nil, nil}) do
    with {:ok, country} <- Map.fetch(@countries, country_code),
         {:ok, coords} <- Map.fetch(country, :coordinates) do
      coords
    else
      :error -> {nil, nil}
    end
  end

  defp maybe_put_default_coordinates(_country_code, coords), do: coords

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {^key, ""} -> nil
      {^key, value} -> value
      _other -> nil
    end
  end

  def all_country_codes! do
    Enum.map(@countries, fn {code, _} -> code end)
  end

  def all_country_options! do
    @countries
    |> Enum.map(fn {code, %{common_name: common_name}} -> {common_name, code} end)
    |> Enum.sort_by(fn {common_name, _} -> common_name end)
  end

  def country_common_name!(country_code) do
    case Map.fetch(@countries, country_code) do
      {:ok, %{common_name: common_name}} -> common_name
      :error -> country_code
    end
  end
end
