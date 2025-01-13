# Used to generate the Firezone regional availability map

import cartopy.crs as ccrs
import cartopy.feature as cfeature
import matplotlib.pyplot as plt

# Complete list of cities with coordinates
coordinates = [
    {"city": "Changhua County, Taiwan", "lon": 120.5169, "lat": 24.0518},
    {"city": "Hong Kong", "lon": 114.1694, "lat": 22.3193},
    {"city": "Tokyo, Japan", "lon": 139.7595, "lat": 35.6828},
    {"city": "Osaka, Japan", "lon": 135.5023, "lat": 34.6937},
    {"city": "Seoul, South Korea", "lon": 126.9780, "lat": 37.5665},
    {"city": "Mumbai, India", "lon": 72.8777, "lat": 19.0760},
    {"city": "Delhi, India", "lon": 77.1025, "lat": 28.7041},
    {"city": "Jurong West, Singapore", "lon": 103.8198, "lat": 1.3521},
    {"city": "Jakarta, Indonesia", "lon": 106.8456, "lat": -6.2088},
    {"city": "Sydney, Australia", "lon": 151.2093, "lat": -33.8688},
    {"city": "Melbourne, Australia", "lon": 144.9631, "lat": -37.8136},
    {"city": "Warsaw, Poland", "lon": 21.0122, "lat": 52.2297},
    {"city": "Hamina, Finland", "lon": 27.1979, "lat": 60.5690},
    {"city": "St. Ghislain, Belgium", "lon": 3.8186, "lat": 50.4541},
    {"city": "London, UK", "lon": -0.1278, "lat": 51.5074},
    {"city": "Frankfurt, Germany", "lon": 8.6821, "lat": 50.1109},
    {"city": "Eemshaven, Netherlands", "lon": 6.8647, "lat": 53.4386},
    {"city": "Zurich, Switzerland", "lon": 8.5417, "lat": 47.3769},
    {"city": "Milan, Italy", "lon": 9.1900, "lat": 45.4642},
    {"city": "Paris, France", "lon": 2.3522, "lat": 48.8566},
    {"city": "Berlin, Germany", "lon": 13.4050, "lat": 52.5200},
    {"city": "Turin, Italy", "lon": 7.6869, "lat": 45.0703},
    {"city": "Madrid, Spain", "lon": -3.7038, "lat": 40.4168},
    {"city": "Doha, Qatar", "lon": 51.2285, "lat": 25.2760},
    {"city": "Tel Aviv, Israel", "lon": 34.7818, "lat": 32.0853},
    {"city": "Montréal, Canada", "lon": -73.5673, "lat": 45.5017},
    {"city": "Toronto, Canada", "lon": -79.3837, "lat": 43.6511},
    {"city": "Querétaro, Mexico", "lon": -100.3899, "lat": 20.5888},
    {"city": "Santiago, Chile", "lon": -70.6693, "lat": -33.4489},
    {"city": "Osasco, São Paulo, Brazil", "lon": -46.7910, "lat": -23.5329},
    {"city": "Council Bluffs, Iowa, USA", "lon": -95.8608, "lat": 41.2619},
    {"city": "Moncks Corner, South Carolina, USA", "lon": -79.9989, "lat": 33.1960},
    {"city": "Ashburn, Northern Virginia, USA", "lon": -77.4874, "lat": 39.0438},
    {"city": "Columbus, Ohio, USA", "lon": -82.9988, "lat": 39.9612},
    {"city": "Dallas, Texas, USA", "lon": -96.7970, "lat": 32.7767},
    {"city": "The Dalles, Oregon, USA", "lon": -121.1787, "lat": 45.5946},
    {"city": "Los Angeles, California, USA", "lon": -118.2437, "lat": 34.0522},
    {"city": "Salt Lake City, Utah, USA", "lon": -111.8910, "lat": 40.7608},
    {"city": "Las Vegas, Nevada, USA", "lon": -115.1398, "lat": 36.1699},
    {"city": "Johannesburg, South Africa", "lon": 28.0473, "lat": -26.2041},
]

# Create a map with equirectangular projection
fig = plt.figure(figsize=(14, 7))
ax = plt.axes(projection=ccrs.PlateCarree())  # Equirectangular projection
ax.set_global()
ax.coastlines()

# Plot the cities
for city in coordinates:
    ax.plot(city["lon"], city["lat"], marker="o", color="#ff7300", markersize=10, transform=ccrs.PlateCarree())

# Add features and titles
ax.add_feature(cfeature.BORDERS, linestyle=":")
ax.add_feature(cfeature.LAND, edgecolor="#1b140e", facecolor="#f8f7f7")
plt.subplots_adjust(left=0, right=1, top=1, bottom=0)  # Extend map to borders

ax.axis("off")

plt.show()
