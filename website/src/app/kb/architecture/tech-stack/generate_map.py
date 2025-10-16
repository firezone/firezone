# Used to generate the Firezone regional availability map

import cartopy.crs as ccrs
import cartopy.feature as cfeature
import matplotlib.pyplot as plt

# Azure regions with coordinates
coordinates = [
    {"city": "Virginia (East US)", "lon": -79.8164, "lat": 37.3719},
    {"city": "Washington (West US 2)", "lon": -119.852, "lat": 47.233},
    {"city": "Netherlands (West Europe)", "lon": 4.8945, "lat": 52.3667},
    {"city": "Singapore (Southeast Asia)", "lon": 103.833, "lat": 1.283},
    {"city": "Tokyo (Japan East)", "lon": 139.77, "lat": 35.68},
    {"city": "London (UK South)", "lon": -0.799, "lat": 50.941},
    {"city": "São Paulo (Brazil South)", "lon": -46.633, "lat": -23.55},
    {"city": "Sydney (Australia East)", "lon": 151.2094, "lat": -33.86},
    {"city": "Pune (Central India)", "lon": 73.9197, "lat": 18.5822},
    {"city": "Toronto (Canada Central)", "lon": -79.383, "lat": 43.653},
    {"city": "Dubai (UAE North)", "lon": 55.316, "lat": 25.266},
    {"city": "Frankfurt (Germany West Central)", "lon": 8.682127, "lat": 50.110924},
    {"city": "Seoul (Korea Central)", "lon": 126.9780, "lat": 37.5665},
    {"city": "Paris (France Central)", "lon": 2.3522, "lat": 48.8566},
    {"city": "Johannesburg (South Africa North)", "lon": 28.030, "lat": -26.198},
    {"city": "Ireland (North Europe)", "lon": -6.2603, "lat": 53.3498},
    {"city": "Virginia (East US 2)", "lon": -78.3889, "lat": 36.6681},
    {"city": "Phoenix (West US 3)", "lon": -112.074, "lat": 33.448},
    {"city": "Zurich (Switzerland North)", "lon": 8.564572, "lat": 47.451542},
    {"city": "Oslo (Norway East)", "lon": 10.752, "lat": 59.913},
    {"city": "Warsaw (Poland Central)", "lon": 21.017, "lat": 52.237},
    {"city": "Doha (Qatar Central)", "lon": 51.183, "lat": 25.317},
    {"city": "Iowa (Central US)", "lon": -93.6208, "lat": 41.5908},
    {"city": "Querétaro (Mexico Central)", "lon": -100.389, "lat": 20.589},
    {"city": "Hong Kong (East Asia)", "lon": 114.188, "lat": 22.267},
    {"city": "Milan (Italy North)", "lon": 9.1824, "lat": 45.4685},
    {"city": "Kuala Lumpur (Malaysia West)", "lon": 101.687, "lat": 3.139},
    {"city": "Santiago (Chile Central)", "lon": -70.673, "lat": -33.447},
    {"city": "Tel Aviv (Israel Central)", "lon": 34.851, "lat": 31.045},
    {"city": "Madrid (Spain Central)", "lon": -3.7026, "lat": 40.4165},
    {"city": "Jakarta (Indonesia Central)", "lon": 106.8456, "lat": -6.2088},
    {"city": "Gävle (Sweden Central)", "lon": 17.1413, "lat": 60.6749},
    {"city": "Auckland (New Zealand North)", "lon": 174.763, "lat": -36.848},
    {"city": "Illinois (North Central US)", "lon": -87.6278, "lat": 41.8819},
]

# Create a map with equirectangular projection
fig = plt.figure(figsize=(14, 7))
ax = plt.axes(projection=ccrs.PlateCarree())  # Equirectangular projection
ax.set_global()
ax.coastlines()

# Plot the cities
for city in coordinates:
    ax.plot(
        city["lon"],
        city["lat"],
        marker="o",
        color="#ff7300",
        markersize=10,
        transform=ccrs.PlateCarree(),
    )

# Add features and titles
ax.add_feature(cfeature.BORDERS, linestyle=":")
ax.add_feature(cfeature.LAND, edgecolor="#1b140e", facecolor="#f8f7f7")
plt.subplots_adjust(left=0, right=1, top=1, bottom=0)  # Extend map to borders

ax.axis("off")

# Save the figure
output_path = "./regional-availability.png"
plt.savefig(output_path, dpi=150, bbox_inches="tight", pad_inches=0)
print(
    f"Map saved to {output_path}. Move this file to the public/images directory appropriately."
)

plt.show()
