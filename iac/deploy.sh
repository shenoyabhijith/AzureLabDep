#!/bin/bash

# Exit on any error
set -e

echo "Starting deployment of Azure Movie Database Architecture..."

# Generate a unique suffix for Cosmos DB account (lowercase letters and numbers)
RANDOM_SUFFIX=$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)
COSMOS_ACCOUNT="moviedatabase${RANDOM_SUFFIX}"
echo "Using unique Cosmos DB account name: $COSMOS_ACCOUNT"

# Check Azure CLI version
echo "Azure CLI version: $(az --version | head -n 1)"

# Check subscription status
echo "Checking Azure subscription..."
az account show

# Variables
RESOURCE_GROUP=$1
LOCATION="eastus"
STORAGE_ACCOUNT="moviedatabasesa${RANDOM_SUFFIX}"
DB_NAME="moviedb"
CONTAINER_NAME="movies"
FUNCTION_APP="moviedbfunc"
PYTHON_VERSION="3.12"
FUNCTIONS_VERSION="4"

# Function to retry commands with exponential backoff
retry_command() {
    local max_attempts=5
    local timeout=30
    local attempt=1
    local exitCode=0

    while [[ $attempt -le $max_attempts ]]
    do
        echo "Attempt $attempt of $max_attempts: $@"
        
        "$@"
        exitCode=$?

        if [[ $exitCode == 0 ]]
        then
            return 0
        fi

        echo "Command failed with exit code $exitCode. Retrying in $timeout seconds..."
        sleep $timeout
        
        # Exponential backoff with jitter
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
    done

    return $exitCode
}

# Create storage account
echo "Creating storage account..."
az storage account create \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Standard_LRS \
  --kind StorageV2

# Enable static website hosting
echo "Enabling static website hosting..."
az storage blob service-properties update \
  --account-name $STORAGE_ACCOUNT \
  --static-website \
  --index-document index.html \
  --404-document 404.html

# Get website URL
WEBSITE_URL=$(az storage account show \
  --name $STORAGE_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query "primaryEndpoints.web" \
  --output tsv)

echo "Static website URL: $WEBSITE_URL"

# Create Cosmos DB account with verbose output
echo "Creating Cosmos DB account..."
az cosmosdb create \
  --name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --locations regionName=$LOCATION failoverPriority=0 isZoneRedundant=False \
  --debug

# Function to check Cosmos DB status
check_cosmos_status() {
    status=$(az cosmosdb show \
        --name $COSMOS_ACCOUNT \
        --resource-group $RESOURCE_GROUP \
        --query "provisioningState" \
        -o tsv)
    echo $status
}

# Wait for Cosmos DB to be online
echo "Waiting for Cosmos DB to be online..."
while true; do
    status=$(check_cosmos_status)
    echo "Current status: $status"
    if [ "$status" == "Succeeded" ]; then
        echo "Cosmos DB provisioning succeeded"
        break
    fi
    echo "Waiting 30 seconds before checking again..."
    sleep 30
done

# Additional wait to ensure service is fully operational
echo "Waiting additional 3 minutes for all services to be fully operational..."
sleep 180

# Create database
echo "Creating database..."
retry_command az cosmosdb sql database create \
  --account-name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --name $DB_NAME

# Create container
echo "Creating container..."
retry_command az cosmosdb sql container create \
  --account-name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --database-name $DB_NAME \
  --name $CONTAINER_NAME \
  --partition-key-path /genre

# Get Cosmos DB connection string
COSMOS_KEY=$(az cosmosdb keys list \
  --name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --type keys \
  --query "primaryMasterKey" \
  -o tsv)

COSMOS_ENDPOINT=$(az cosmosdb show \
  --name $COSMOS_ACCOUNT \
  --resource-group $RESOURCE_GROUP \
  --query "documentEndpoint" \
  -o tsv)

# Download movie dataset
echo "Downloading movie dataset..."
wget https://raw.githubusercontent.com/LearnDataSci/articles/refs/heads/master/Python%20Pandas%20Tutorial%20A%20Complete%20Introduction%20for%20Beginners/IMDB-Movie-Data.csv

# Create Python import script
echo "Creating Python import script..."
cat > import_movies.py << 'EOF'
import os
import csv
from azure.cosmos import CosmosClient, exceptions

# Set your Cosmos DB credentials
COSMOS_DB_URL = os.environ['COSMOS_ENDPOINT']
COSMOS_DB_KEY = os.environ['COSMOS_KEY']
DATABASE_NAME = os.environ['DB_NAME']
CONTAINER_NAME = os.environ['CONTAINER_NAME']

# Initialize the Cosmos client
client = CosmosClient(COSMOS_DB_URL, credential=COSMOS_DB_KEY)
try:
    database = client.get_database_client(DATABASE_NAME)
    container = database.get_container_client(CONTAINER_NAME)
except exceptions.CosmosResourceNotFoundError:
    print("Database or container not found. Please verify your setup.")
    exit()

# Path to the uploaded CSV file
csv_file_path = 'IMDB-Movie-Data.csv'

try:
    # Read the CSV file and upsert items into Cosmos DB
    with open(csv_file_path, mode='r', encoding='utf-8') as file:
        csv_reader = csv.DictReader(file)
        
        for row in csv_reader:
            try:
                # Transform CSV row to match Cosmos DB schema
                item = {
                    'id': row['Rank'],  # Using 'Rank' as unique identifier
                    'title': row['Title'],
                    'genre': row['Genre'],  # Matches partition key
                    'description': row['Description'],
                    'director': row['Director'],
                    'actors': row['Actors'],
                    'year': int(row['Year']),
                    'runtime': int(row['Runtime (Minutes)']),
                    'rating': float(row['Rating']),
                    'votes': int(row['Votes']),
                    'revenue': float(row['Revenue (Millions)']) if row.get('Revenue (Millions)') and row['Revenue (Millions)'] else None,
                    'metascore': int(row['Metascore']) if row.get('Metascore') and row['Metascore'] else None
                }
                container.upsert_item(item)
                print(f"Upserted item with id: {item['id']}")
            except KeyError as e:
                print(f"Skipping row due to missing key: {e}")
            except ValueError as e:
                print(f"Skipping row due to value conversion error: {e}")
except FileNotFoundError:
    print(f"CSV file not found at path: {csv_file_path}")
except Exception as e:
    print(f"An unexpected error occurred: {e}")

print("Data import completed.")
EOF

echo "Installing dependencies and importing data..."

# Ensure ~/.local/bin is in PATH so newly installed tools are found
export PATH="$HOME/.local/bin:$PATH"

# Upgrade pip in the user site and install Cosmos SDK (+deps)
python -m pip install --user --upgrade pip
python -m pip install --user "azure-cosmos>=4.8.0"

# Run the import script with the same interpreter
COSMOS_ENDPOINT=$COSMOS_ENDPOINT \
COSMOS_KEY=$COSMOS_KEY \
DB_NAME=$DB_NAME \
CONTAINER_NAME=$CONTAINER_NAME \
python import_movies.py

# Create static website files
echo "Creating static website files..."
mkdir -p website

# Create index.html with embedded CSS and JS
cat > website/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MovieFinder</title>
    <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500&display=swap" rel="stylesheet">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/5.15.4/css/all.min.css">
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Roboto', sans-serif;
            background: #1a1a1a;
            display: flex;
            justify-content: center;
            align-items: center;
            min-height: 100vh;
            color: white;
        }

        .container {
            width: 100%;
            max-width: 600px;
            padding: 20px;
        }

        .search-container {
            text-align: center;
        }

        .logo {
            width: 150px;
            margin-bottom: 30px;
            animation: fadeIn 1s ease-in;
        }

        .search-box {
            position: relative;
            margin: 0 auto;
            max-width: 580px;
            width: 100%;
        }

        .search-box input {
            width: 100%;
            padding: 15px 45px;
            border: none;
            border-radius: 30px;
            background: #333;
            color: white;
            font-size: 16px;
            transition: all 0.3s ease;
        }

        .search-box input:focus {
            background: #444;
            outline: none;
            box-shadow: 0 0 15px rgba(255, 255, 255, 0.1);
        }

        .search-icon, .mic-icon {
            position: absolute;
            top: 50%;
            transform: translateY(-50%);
            color: #888;
            font-size: 18px;
        }

        .search-icon {
            left: 15px;
        }

        .mic-icon {
            right: 15px;
            cursor: pointer;
            transition: color 0.3s ease;
        }

        .mic-icon:hover {
            color: #4285f4;
        }

        .buttons {
            margin-top: 30px;
        }

        .search-btn {
            padding: 12px 20px;
            margin: 0 5px;
            border: none;
            border-radius: 5px;
            background: #333;
            color: white;
            font-size: 14px;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        .search-btn:hover {
            background: #444;
            box-shadow: 0 0 10px rgba(255, 255, 255, 0.1);
        }

        @keyframes fadeIn {
            from {
                opacity: 0;
                transform: translateY(-20px);
            }
            to {
                opacity: 1;
                transform: translateY(0);
            }
        }

        @media (max-width: 600px) {
            .search-box input {
                font-size: 14px;
            }
            
            .buttons {
                display: flex;
                flex-direction: column;
                gap: 10px;
            }
            
            .search-btn {
                width: 100%;
                margin: 0;
            }
        }

        .results-container {
            margin-top: 30px;
            background: #333;
            border-radius: 10px;
            padding: 20px;
            display: none;
            animation: fadeIn 0.5s ease-in;
        }
        
        .movie-table {
            width: 100%;
            border-collapse: collapse;
            margin-top: 15px;
        }
        
        .movie-table th, .movie-table td {
            padding: 12px;
            text-align: left;
            border-bottom: 1px solid #444;
        }
        
        .movie-table th {
            background-color: #222;
            color: #f0f0f0;
        }
        
        .movie-info {
            display: flex;
            align-items: flex-start;
            margin-bottom: 20px;
        }
        
        .movie-poster {
            width: 150px;
            border-radius: 5px;
            margin-right: 20px;
        }
        
        .movie-details h2 {
            margin-bottom: 10px;
        }
        
        .movie-details p {
            margin-bottom: 5px;
            color: #ccc;
        }
        
        .error-message {
            color: #ff6b6b;
            padding: 15px;
            text-align: center;
            background: rgba(255, 107, 107, 0.1);
            border-radius: 5px;
        }
        
        .loading {
            text-align: center;
            padding: 20px;
        }
        
        .loading::after {
            content: "...";
            animation: dots 1.5s steps(5, end) infinite;
        }
        
        @keyframes dots {
            0%, 20% { content: "."; }
            40% { content: ".."; }
            60%, 100% { content: "..."; }
        }

        /* Settings styles */
        .settings-btn {
            position: fixed;
            top: 20px;
            right: 20px;
            padding: 10px;
            background: #333;
            border: none;
            border-radius: 5px;
            color: white;
            cursor: pointer;
        }

        .settings-modal {
            display: none;
            position: fixed;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            background: #333;
            padding: 20px;
            border-radius: 10px;
            z-index: 1000;
            width: 90%;
            max-width: 500px;
        }

        .modal-backdrop {
            display: none;
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(0, 0, 0, 0.7);
            z-index: 999;
        }

        .settings-modal h2 {
            margin-bottom: 20px;
        }

        .settings-modal label {
            display: block;
            margin-bottom: 5px;
        }

        .settings-modal input {
            width: 100%;
            padding: 8px;
            margin-bottom: 15px;
            background: #444;
            border: 1px solid #555;
            color: white;
            border-radius: 4px;
        }

        .settings-modal button {
            padding: 8px 15px;
            margin-right: 10px;
            border: none;
            border-radius: 4px;
            cursor: pointer;
        }

        .settings-modal .save-btn {
            background: #4285f4;
            color: white;
        }

        .settings-modal .cancel-btn {
            background: #666;
            color: white;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="search-container">
            <img src="https://cdn-icons-png.flaticon.com/512/3418/3418886.png" alt="MovieFinder" class="logo">
            <div class="search-box">
                <i class="fas fa-search search-icon"></i>
                <input type="text" placeholder="Search for movies..." id="searchInput">
                <i class="fas fa-microphone mic-icon"></i>
            </div>
            <div class="buttons">
                <button class="search-btn">Search Movies</button>
            </div>
        </div>
        
        <div class="results-container" id="resultsContainer">
            <!-- Results will be displayed here -->
        </div>
    </div>
    <button class="settings-btn">
        <i class="fas fa-cog"></i>
    </button>

    <div class="modal-backdrop"></div>
    <div class="settings-modal">
        <h2>API Settings</h2>
        <label for="apiUrl">API URL:</label>
        <input type="text" id="apiUrl" placeholder="Enter API URL">
        
        <label for="apiKey">API Key:</label>
        <input type="text" id="apiKey" placeholder="Enter API Key">
        
        <button class="save-btn">Save</button>
        <button class="cancel-btn">Cancel</button>
    </div>
    <script>
        document.addEventListener('DOMContentLoaded', () => {
            const searchInput = document.querySelector('#searchInput');
            const searchButton = document.querySelector('.search-btn');
            const micIcon = document.querySelector('.mic-icon');
            const resultsContainer = document.querySelector('#resultsContainer');

            // Settings functionality
            const settingsBtn = document.querySelector('.settings-btn');
            const settingsModal = document.querySelector('.settings-modal');
            const modalBackdrop = document.querySelector('.modal-backdrop');
            const apiUrlInput = document.getElementById('apiUrl');
            const apiKeyInput = document.getElementById('apiKey');
            const saveBtn = document.querySelector('.save-btn');
            const cancelBtn = document.querySelector('.cancel-btn');

            // Default API settings
            let apiSettings = {
                url: 'https://moviedbgateway.azure-api.net/movie_stats/movie_stats',
                key: '4308738d844e4ae6947a5f74ff5d9e3f'
            };

            // Load saved settings from localStorage
            const loadSettings = () => {
                const savedSettings = localStorage.getItem('apiSettings');
                if (savedSettings) {
                    apiSettings = JSON.parse(savedSettings);
                }
                apiUrlInput.value = apiSettings.url;
                apiKeyInput.value = apiSettings.key;
            };

            // Save settings to localStorage
            const saveSettings = () => {
                apiSettings.url = apiUrlInput.value.trim();
                apiSettings.key = apiKeyInput.value.trim();
                localStorage.setItem('apiSettings', JSON.stringify(apiSettings));
                closeModal();
            };

            // Modal controls
            const openModal = () => {
                settingsModal.style.display = 'block';
                modalBackdrop.style.display = 'block';
                loadSettings();
            };

            const closeModal = () => {
                settingsModal.style.display = 'none';
                modalBackdrop.style.display = 'none';
            };

            settingsBtn.addEventListener('click', openModal);
            modalBackdrop.addEventListener('click', closeModal);
            cancelBtn.addEventListener('click', closeModal);
            saveBtn.addEventListener('click', saveSettings);

            // Search functionality
            const performSearch = () => {
                const searchTerm = searchInput.value.trim();
                if (searchTerm) {
                    resultsContainer.style.display = 'block';
                    resultsContainer.innerHTML = '<div class="loading">Fetching movie data</div>';
                    
                    const apiUrl = `${apiSettings.url}?title=${encodeURIComponent(searchTerm)}`;
                    
                    fetch(apiUrl, {
                        headers: {
                            'Ocp-Apim-Subscription-Key': apiSettings.key
                        }
                    })
                    .then(response => {
                        if (!response.ok) {
                            throw new Error("Network response was not ok: " + response.status);
                        }
                        return response.json();
                    })
                    .then(data => {
                        displayMovieData(data);
                    })
                    .catch(error => {
                        resultsContainer.innerHTML = `
                            <div class="error-message">
                                <p>Error: ${error.message}</p>
                                <p>Please try again later or check your search term.</p>
                            </div>
                        `;
                        console.error("API Error:", error);
                    });
                }
            };
            
            const displayMovieData = (response) => {
                const data = response.stats;
                
                if (!data || Object.keys(data).length === 0) {
                    resultsContainer.innerHTML = `
                        <div class="error-message">
                            <p>No movie data found for this search term.</p>
                            <p>Please try a different movie title.</p>
                        </div>
                    `;
                    return;
                }
                
                let htmlContent = `
                    <div class="movie-info">
                        <div class="movie-details">
                            <h2>${data.Title || 'Unknown Title'}</h2>
                            <p>${data.Year || 'Unknown Year'} | ${data['Runtime (Minutes)'] + ' min' || 'Unknown Duration'}</p>
                            <p>Genre: ${data.Genre || 'Unknown'}</p>
                            <p>Director: ${data.Director || 'Unknown'}</p>
                            <p>Actors: ${data.Actors || 'Unknown'}</p>
                        </div>
                    </div>
                `;
                
                if (data.Description) {
                    htmlContent += `
                        <h3>Plot</h3>
                        <p>${data.Description}</p>
                    `;
                }
                
                htmlContent += `
                    <h3>Movie Statistics</h3>
                    <table class="movie-table">
                        <tbody>
                            <tr>
                                <td>Rating</td>
                                <td>${data.Rating || 'Not rated'} / 10</td>
                            </tr>
                            <tr>
                                <td>Votes</td>
                                <td>${data.Votes?.toLocaleString() || '0'}</td>
                            </tr>
                            <tr>
                                <td>Revenue</td>
                                <td>${data['Revenue (Millions)'] ? '$' + data['Revenue (Millions)'] + 'M' : 'Not available'}</td>
                            </tr>
                            <tr>
                                <td>Metascore</td>
                                <td>${data.Metascore || 'Not available'}</td>
                            </tr>
                            ${data.Rank ? `
                            <tr>
                                <td>Rank</td>
                                <td>${data.Rank}</td>
                            </tr>
                            ` : ''}
                        </tbody>
                    </table>
                `;
                
                resultsContainer.innerHTML = htmlContent;
                resultsContainer.style.display = 'block';
            };

            searchButton.addEventListener('click', performSearch);
            searchInput.addEventListener('keypress', (e) => {
                if (e.key === 'Enter') {
                    performSearch();
                }
            });

            if ('webkitSpeechRecognition' in window) {
                const recognition = new webkitSpeechRecognition();
                recognition.continuous = false;
                recognition.interimResults = false;

                recognition.onresult = (event) => {
                    const transcript = event.results[0][0].transcript;
                    searchInput.value = transcript;
                    performSearch();
                };

                micIcon.addEventListener('click', () => {
                    recognition.start();
                });
            } else {
                micIcon.style.display = 'none';
            }

            loadSettings();
        });
    </script>
</body>
</html>
EOF

# Create 404.html
cat > website/404.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Page Not Found</title>
    <style>
        body {
            font-family: 'Roboto', sans-serif;
            background: #1a1a1a;
            color: white;
            height: 100vh;
            margin: 0;
            display: flex;
            align-items: center;
            justify-content: center;
            text-align: center;
        }
        .error-container {
            max-width: 500px;
            padding: 20px;
        }
        h1 {
            font-size: 72px;
            margin: 0;
        }
        .btn {
            display: inline-block;
            padding: 12px 24px;
            background: #333;
            color: white;
            text-decoration: none;
            border-radius: 5px;
            margin-top: 20px;
            transition: background 0.3s ease;
        }
        .btn:hover {
            background: #444;
        }
    </style>
</head>
<body>
    <div class="error-container">
        <h1>404</h1>
        <h2>Page Not Found</h2>
        <p>The page you are looking for doesn't exist or has been moved.</p>
        <a href="/" class="btn">Go to Homepage</a>
    </div>
</body>
</html>
EOF

# Upload website files to blob storage
echo "Uploading website files..."
az storage blob upload-batch \
  --account-name $STORAGE_ACCOUNT \
  --auth-mode key \
  --destination '$web' \
  --source website \
  --overwrite

echo "Deployment completed successfully!"
echo "Website URL: $WEBSITE_URL"
