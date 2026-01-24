// DOM Elements
const barcodeInput = document.getElementById('barcodeInput');
const submitBarcode = document.getElementById('submitBarcode');
const stopButton = document.getElementById('stopButton');
const statusMessage = document.getElementById('statusMessage');
const recordingIndicator = document.getElementById('recordingIndicator');
const recordingDuration = document.getElementById('recordingDuration');
const systemStatus = document.getElementById('systemStatus');
const currentFilename = document.getElementById('currentFilename');
const storageUsed = document.getElementById('storageUsed');
const recordingsList = document.getElementById('recordingsList');
const searchInput = document.getElementById('searchInput');
const searchButton = document.getElementById('searchButton');
const searchResults = document.getElementById('searchResults');
const startDateInput = document.getElementById('startDateInput');
const endDateInput = document.getElementById('endDateInput');
const sortBySelect = document.getElementById('sortBySelect');
const limitSelect = document.getElementById('limitSelect');
const clearFiltersButton = document.getElementById('clearFiltersButton');
const searchResultsInfo = document.getElementById('searchResultsInfo');
const searchResultsCount = document.getElementById('searchResultsCount');
const searchPagination = document.getElementById('searchPagination');

// State
let isRecording = false;
let recordingStartTime = null;
let statusCheckInterval = null;
let durationUpdateInterval = null;
let currentSearchPage = 0;
let totalSearchResults = 0;

// Initialize
document.addEventListener('DOMContentLoaded', () => {
    loadRecordings();
    startStatusPolling();
    setupEventListeners();
});

// Event Listeners
function setupEventListeners() {
    // Submit barcode button
    submitBarcode.addEventListener('click', handleBarcodeSubmit);

    // Enter key in barcode input
    barcodeInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            handleBarcodeSubmit();
        }
    });

    // Stop button
    stopButton.addEventListener('click', handleManualStop);

    // Search button
    searchButton.addEventListener('click', () => handleAdvancedSearch(0));

    // Clear filters button
    clearFiltersButton.addEventListener('click', clearSearchFilters);

    // Enter key in search input
    searchInput.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') {
            handleAdvancedSearch(0);
        }
    });

    // Settings button
    const settingsButton = document.getElementById('settingsButton');
    if (settingsButton) {
        settingsButton.addEventListener('click', openSettingsModal);
    }

    // Search Recordings button
    const searchRecordingsButton = document.getElementById('searchRecordingsButton');
    if (searchRecordingsButton) {
        searchRecordingsButton.addEventListener('click', openSearchModal);
    }

    // Settings tabs
    const settingsTabs = document.querySelectorAll('.settings-tab');
    settingsTabs.forEach(tab => {
        tab.addEventListener('click', () => switchSettingsTab(tab.dataset.tab));
    });

    // Keyboard shortcuts
    document.addEventListener('keydown', (e) => {
        // ESC to close search modal
        if (e.key === 'Escape') {
            const searchModal = document.getElementById('searchModal');
            if (searchModal && !searchModal.classList.contains('hidden')) {
                closeSearchModal();
            }
        }

        // Ctrl+F to open search modal
        if (e.ctrlKey && e.key === 'f') {
            e.preventDefault();
            openSearchModal();
        }
    });
}

// Handle barcode submission
async function handleBarcodeSubmit() {
    const barcode = barcodeInput.value.trim();

    if (!barcode) {
        showStatus('Please enter a barcode', 'error');
        return;
    }

    try {
        const response = await fetch('/api/barcode', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ barcode })
        });

        const data = await response.json();

        if (!response.ok) {
            showStatus(data.error || 'Error processing barcode', 'error');
            return;
        }

        if (data.action === 'started') {
            isRecording = true;
            recordingStartTime = Date.now();
            showStatus(`Recording started: ${data.barcode}`, 'success');
            updateUIForRecording(true, data.filename);
            startDurationTimer();
        } else if (data.action === 'stop_and_start') {
            // Switched to new recording
            isRecording = true;
            recordingStartTime = Date.now();
            showStatus(`Switched to: ${data.barcode} (Previous: ${data.previous_duration}s)`, 'success');
            updateUIForRecording(true, data.new_filename);
            loadRecordings();
        } else if (data.action === 'stopped') {
            isRecording = false;
            recordingStartTime = null;
            showStatus(`Recording stopped: ${data.duration}s, ${data.file_size_mb}MB`, 'success');
            updateUIForRecording(false);
            stopDurationTimer();
            loadRecordings();
        }

        // Clear input
        barcodeInput.value = '';
        barcodeInput.focus();

    } catch (error) {
        console.error('Error submitting barcode:', error);
        showStatus('Network error. Please try again.', 'error');
    }
}

// Handle manual stop
async function handleManualStop() {
    try {
        const response = await fetch('/api/stop', {
            method: 'POST'
        });

        const data = await response.json();

        if (!response.ok) {
            showStatus(data.error || 'Error stopping recording', 'error');
            return;
        }

        isRecording = false;
        recordingStartTime = null;
        showStatus(`Recording stopped manually: ${data.duration}s, ${data.file_size_mb}MB`, 'success');
        updateUIForRecording(false);
        stopDurationTimer();
        loadRecordings();
        barcodeInput.focus();

    } catch (error) {
        console.error('Error stopping recording:', error);
        showStatus('Network error. Please try again.', 'error');
    }
}

// Update UI based on recording state
function updateUIForRecording(recording, filename = '-') {
    if (recording) {
        recordingIndicator.classList.remove('hidden');
        stopButton.disabled = false;
        // Keep input enabled for continuous scanning
        submitBarcode.disabled = false;
        barcodeInput.disabled = false;
        systemStatus.textContent = 'Recording';
        systemStatus.className = 'status-recording';
        currentFilename.textContent = filename;
    } else {
        recordingIndicator.classList.add('hidden');
        stopButton.disabled = true;
        submitBarcode.disabled = false;
        barcodeInput.disabled = false;
        systemStatus.textContent = 'Idle';
        systemStatus.className = 'status-idle';
        currentFilename.textContent = '-';
        recordingDuration.textContent = '00:00';
    }
}

// Show status message
function showStatus(message, type) {
    statusMessage.textContent = message;
    statusMessage.className = `status-message ${type}`;

    // Auto-hide after 5 seconds
    setTimeout(() => {
        statusMessage.style.display = 'none';
        statusMessage.className = 'status-message';
    }, 5000);
}

// Format duration
function formatDuration(seconds) {
    const mins = Math.floor(seconds / 60);
    const secs = seconds % 60;
    return `${String(mins).padStart(2, '0')}:${String(secs).padStart(2, '0')}`;
}

// Start duration timer
function startDurationTimer() {
    durationUpdateInterval = setInterval(() => {
        if (recordingStartTime) {
            const elapsed = Math.floor((Date.now() - recordingStartTime) / 1000);
            recordingDuration.textContent = formatDuration(elapsed);
        }
    }, 1000);
}

// Stop duration timer
function stopDurationTimer() {
    if (durationUpdateInterval) {
        clearInterval(durationUpdateInterval);
        durationUpdateInterval = null;
    }
}

// Poll status from server
async function checkStatus() {
    try {
        const response = await fetch('/api/status');
        const data = await response.json();

        if (response.ok) {
            // Update storage info
            storageUsed.textContent = `${data.storage_used_mb.toFixed(2)} MB`;

            // Sync recording state
            if (data.recording && !isRecording) {
                isRecording = true;
                updateUIForRecording(true, data.filename);
                recordingStartTime = Date.now() - (data.duration * 1000);
                startDurationTimer();
            } else if (!data.recording && isRecording) {
                isRecording = false;
                updateUIForRecording(false);
                stopDurationTimer();
            }
        }
    } catch (error) {
        console.error('Error checking status:', error);
    }
}

// Start status polling
function startStatusPolling() {
    statusCheckInterval = setInterval(checkStatus, 2000);
}

// Load recent recordings
async function loadRecordings() {
    try {
        const response = await fetch('/api/recordings?limit=10');
        const recordings = await response.json();

        if (!response.ok) {
            recordingsList.innerHTML = '<p class="loading">Error loading recordings</p>';
            return;
        }

        if (recordings.length === 0) {
            recordingsList.innerHTML = '<p class="loading">No recordings yet</p>';
            return;
        }

        // Build recordings HTML
        const html = recordings.map(rec => {
            const startTime = new Date(rec.start_time).toLocaleString();
            const duration = rec.duration_seconds ? `${rec.duration_seconds}s` : 'N/A';
            const fileSize = rec.file_size_mb ? `${rec.file_size_mb.toFixed(2)}MB` : 'N/A';
            const stopMethod = rec.stop_method || 'N/A';

            return `
                <div class="recording-item">
                    <div class="barcode">${rec.barcode}</div>
                    <div class="details">
                        <strong>Started:</strong> ${startTime} |
                        <strong>Duration:</strong> ${duration} |
                        <strong>Size:</strong> ${fileSize} |
                        <strong>Stop Method:</strong> ${stopMethod}
                    </div>
                    <div class="filename">${rec.video_filename}</div>
                </div>
            `;
        }).join('');

        recordingsList.innerHTML = html;

    } catch (error) {
        console.error('Error loading recordings:', error);
        recordingsList.innerHTML = '<p class="loading">Error loading recordings</p>';
    }
}

// Handle advanced search
async function handleAdvancedSearch(page = 0) {
    currentSearchPage = page;

    const barcode = searchInput.value.trim();
    const startDate = startDateInput.value;
    const endDate = endDateInput.value;
    const sortBy = sortBySelect.value;
    const limit = parseInt(limitSelect.value);
    const offset = page * limit;

    // Parse sort option
    let sortColumn = 'created_at';
    let sortOrder = 'DESC';

    if (sortBy === 'created_at_asc') {
        sortColumn = 'created_at';
        sortOrder = 'ASC';
    } else if (sortBy === 'barcode') {
        sortColumn = 'barcode';
        sortOrder = 'ASC';
    } else if (sortBy === 'duration_seconds' || sortBy === 'file_size_mb') {
        sortColumn = sortBy;
        sortOrder = 'DESC';
    }

    // Build query string
    const params = new URLSearchParams();
    if (barcode) params.append('barcode', barcode);
    if (startDate) params.append('start_date', startDate);
    if (endDate) params.append('end_date', endDate);
    params.append('sort_by', sortColumn);
    params.append('sort_order', sortOrder);
    params.append('limit', limit);
    params.append('offset', offset);

    try {
        const response = await fetch(`/api/search/advanced?${params.toString()}`);
        const data = await response.json();

        if (!response.ok) {
            searchResults.innerHTML = `<p class="search-placeholder">❌ ${data.error || 'Error searching'}</p>`;
            searchResultsInfo.classList.add('hidden');
            return;
        }

        const results = data.results;
        totalSearchResults = data.total;

        if (results.length === 0) {
            searchResults.innerHTML = '<p class="search-placeholder">📭 No recordings found matching your search criteria</p>';
            searchResultsInfo.classList.add('hidden');
            return;
        }

        // Build search results HTML with beautiful cards
        const html = results.map(rec => {
            const startTime = new Date(rec.start_time).toLocaleString();
            const duration = rec.duration_seconds ? `${rec.duration_seconds}s` : 'N/A';
            const fileSize = rec.file_size_mb ? `${rec.file_size_mb.toFixed(2)}MB` : 'N/A';

            // Build video URLs
            const date = new Date(rec.start_time);
            const dateFolder = date.toISOString().split('T')[0];
            const videoUrl = `/videos/${dateFolder}/${rec.video_filename}`;
            const downloadUrl = `/videos/${dateFolder}/${rec.video_filename}/download`;

            return `
                <div class="search-result-card">
                    <div class="search-result-card-header">
                        <div class="search-result-barcode">
                            📦 ${rec.barcode}
                        </div>
                        <div class="search-result-status">✓ Completed</div>
                    </div>
                    <div class="search-result-details">
                        📅 <strong>Date:</strong> ${startTime} &nbsp;|&nbsp;
                        ⏱️ <strong>Duration:</strong> ${duration} &nbsp;|&nbsp;
                        💾 <strong>Size:</strong> ${fileSize}
                    </div>
                    <div class="search-result-filename">
                        📄 ${rec.video_filename}
                    </div>
                    <div class="search-result-actions">
                        <button class="search-result-btn search-result-btn-play" onclick="viewVideo('${videoUrl}', '${rec.barcode}')">
                            ▶️ Play Video
                        </button>
                        <a href="${downloadUrl}" class="search-result-btn search-result-btn-download" download>
                            ⬇️ Download
                        </a>
                    </div>
                </div>
            `;
        }).join('');

        searchResults.innerHTML = html;

        // Update results info
        const startResult = offset + 1;
        const endResult = Math.min(offset + results.length, totalSearchResults);
        searchResultsCount.textContent = `Showing ${startResult}-${endResult} of ${totalSearchResults} results`;

        // Build pagination
        buildPagination(data.total, limit, page);

        // Show results info
        searchResultsInfo.classList.remove('hidden');

    } catch (error) {
        console.error('Error searching recordings:', error);
        searchResults.innerHTML = '<p class="search-placeholder">❌ Network error while searching recordings</p>';
        searchResultsInfo.classList.add('hidden');
    }
}

// Build pagination controls
function buildPagination(total, limit, currentPage) {
    const totalPages = Math.ceil(total / limit);

    if (totalPages <= 1) {
        searchPagination.innerHTML = '';
        return;
    }

    let html = '';

    // Previous button
    if (currentPage > 0) {
        html += `<button class="pagination-btn" onclick="handleAdvancedSearch(${currentPage - 1})">« Prev</button>`;
    }

    // Page numbers (show 5 pages max)
    const startPage = Math.max(0, currentPage - 2);
    const endPage = Math.min(totalPages - 1, currentPage + 2);

    if (startPage > 0) {
        html += `<button class="pagination-btn" onclick="handleAdvancedSearch(0)">1</button>`;
        if (startPage > 1) html += '<span class="pagination-dots">...</span>';
    }

    for (let i = startPage; i <= endPage; i++) {
        const active = i === currentPage ? 'active' : '';
        html += `<button class="pagination-btn ${active}" onclick="handleAdvancedSearch(${i})">${i + 1}</button>`;
    }

    if (endPage < totalPages - 1) {
        if (endPage < totalPages - 2) html += '<span class="pagination-dots">...</span>';
        html += `<button class="pagination-btn" onclick="handleAdvancedSearch(${totalPages - 1})">${totalPages}</button>`;
    }

    // Next button
    if (currentPage < totalPages - 1) {
        html += `<button class="pagination-btn" onclick="handleAdvancedSearch(${currentPage + 1})">Next »</button>`;
    }

    searchPagination.innerHTML = html;
}

// Clear search filters
function clearSearchFilters() {
    searchInput.value = '';
    startDateInput.value = '';
    endDateInput.value = '';
    sortBySelect.value = 'created_at';
    limitSelect.value = '20';
    searchResults.innerHTML = '<p class="search-placeholder">🔍 Enter search criteria and click Search to find recordings</p>';
    searchResultsInfo.classList.add('hidden');
    currentSearchPage = 0;
    totalSearchResults = 0;
}

// View video in modal
function viewVideo(videoUrl, barcode) {
    // Create modal backdrop
    const modal = document.createElement('div');
    modal.className = 'video-modal';
    modal.innerHTML = `
        <div class="video-modal-content">
            <div class="video-modal-header">
                <h3>📹 Video: ${barcode}</h3>
                <button class="video-modal-close" onclick="closeVideoModal()">&times;</button>
            </div>
            <div class="video-modal-body">
                <video controls autoplay style="width: 100%; max-height: 70vh;">
                    <source src="${videoUrl}" type="video/mp4">
                    Your browser does not support the video tag.
                </video>
            </div>
        </div>
    `;

    // Add to body
    document.body.appendChild(modal);

    // Close on backdrop click
    modal.addEventListener('click', (e) => {
        if (e.target === modal) {
            closeVideoModal();
        }
    });
}

// Close video modal
function closeVideoModal() {
    const modal = document.querySelector('.video-modal');
    if (modal) {
        modal.remove();
    }
}

// ============ Search Modal Functions ============

// Open search modal
function openSearchModal() {
    const modal = document.getElementById('searchModal');
    modal.classList.remove('hidden');

    // Focus on barcode input
    setTimeout(() => {
        const searchInput = document.getElementById('searchInput');
        if (searchInput) {
            searchInput.focus();
        }
    }, 100);
}

// Close search modal
function closeSearchModal() {
    const modal = document.getElementById('searchModal');
    modal.classList.add('hidden');
}

// ============ Settings Functions ============

// Open settings modal
async function openSettingsModal() {
    try {
        // Fetch current settings
        const response = await fetch('/api/settings');
        const settings = await response.json();

        if (!response.ok) {
            showStatus('Error loading settings', 'error');
            return;
        }

        // Load available cameras
        await loadCameras(settings.camera.index);

        // Populate form fields
        populateSettingsForm(settings);

        // Show modal
        const modal = document.getElementById('settingsModal');
        modal.classList.remove('hidden');

    } catch (error) {
        console.error('Error opening settings:', error);
        showStatus('Network error loading settings', 'error');
    }
}

// Close settings modal
function closeSettingsModal() {
    const modal = document.getElementById('settingsModal');
    modal.classList.add('hidden');
}

// Switch settings tab
function switchSettingsTab(tabName) {
    // Remove active from all tabs
    document.querySelectorAll('.settings-tab').forEach(tab => {
        tab.classList.remove('active');
    });

    // Remove active from all tab contents
    document.querySelectorAll('.settings-tab-content').forEach(content => {
        content.classList.remove('active');
    });

    // Add active to selected tab
    document.querySelector(`.settings-tab[data-tab="${tabName}"]`).classList.add('active');
    document.getElementById(`${tabName}Tab`).classList.add('active');
}

// Load available cameras
async function loadCameras(currentIndex = 0) {
    try {
        const response = await fetch('/api/cameras');
        const cameras = await response.json();

        if (!response.ok) {
            console.error('Error loading cameras:', cameras.error);
            return;
        }

        const cameraSelect = document.getElementById('cameraSelect');
        cameraSelect.innerHTML = '';

        if (cameras.length === 0) {
            cameraSelect.innerHTML = '<option value="0">No cameras detected</option>';
            return;
        }

        cameras.forEach(cam => {
            const status = cam.working ? '✓' : '✗';
            const option = document.createElement('option');
            option.value = cam.index;
            option.textContent = `${status} ${cam.name} (Index ${cam.index}) - ${cam.resolution}`;

            if (cam.index === currentIndex) {
                option.selected = true;
            }

            cameraSelect.appendChild(option);
        });

    } catch (error) {
        console.error('Error loading cameras:', error);
    }
}

// Refresh cameras
async function refreshCameras() {
    const currentSelection = document.getElementById('cameraSelect').value;
    await loadCameras(parseInt(currentSelection));
    showStatus('Cameras refreshed', 'success');
}

// Populate settings form
function populateSettingsForm(settings) {
    // Video settings
    const resolution = `${settings.video.resolution_width},${settings.video.resolution_height}`;
    document.getElementById('resolutionSelect').value = resolution;
    document.getElementById('fpsSelect').value = settings.video.fps;
    document.getElementById('codecSelect').value = settings.video.codec;

    // Camera settings - already loaded by loadCameras()
    // document.getElementById('cameraSelect').value is set in loadCameras()

    // Storage settings
    document.getElementById('videoPathInput').value = settings.storage.video_path;
    document.getElementById('dbPathInput').value = settings.storage.database_path;
    document.getElementById('logPathInput').value = settings.storage.log_path;

    // App settings
    document.getElementById('flaskHostInput').value = settings.app.flask_host;
    document.getElementById('flaskPortInput').value = settings.app.flask_port;
    document.getElementById('debugModeCheck').checked = settings.app.debug_mode;
}

// Save settings
async function saveSettings() {
    try {
        // Gather form data
        const resolution = document.getElementById('resolutionSelect').value.split(',');
        const settingsData = {
            video: {
                resolution_width: parseInt(resolution[0]),
                resolution_height: parseInt(resolution[1]),
                fps: parseInt(document.getElementById('fpsSelect').value),
                codec: document.getElementById('codecSelect').value
            },
            camera: {
                index: parseInt(document.getElementById('cameraSelect').value)
            },
            storage: {
                video_path: document.getElementById('videoPathInput').value,
                database_path: document.getElementById('dbPathInput').value,
                log_path: document.getElementById('logPathInput').value
            },
            app: {
                flask_host: document.getElementById('flaskHostInput').value,
                flask_port: parseInt(document.getElementById('flaskPortInput').value),
                debug_mode: document.getElementById('debugModeCheck').checked
            }
        };

        // Save settings
        const response = await fetch('/api/settings', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(settingsData)
        });

        const data = await response.json();

        if (!response.ok) {
            showStatus(data.error || 'Error saving settings', 'error');
            return;
        }

        // Close modal
        closeSettingsModal();

        // Try to restart camera automatically
        try {
            const restartResponse = await fetch('/api/camera/restart', {
                method: 'POST'
            });

            const restartData = await restartResponse.json();

            if (restartResponse.ok) {
                showStatus('Settings saved successfully. Camera restarted with new settings.', 'success');
            } else {
                showStatus('Settings saved, but camera restart failed: ' + restartData.error, 'error');
            }
        } catch (restartError) {
            console.error('Error restarting camera:', restartError);
            showStatus('Settings saved successfully. Please restart the application for all changes to take effect.', 'success');
        }

    } catch (error) {
        console.error('Error saving settings:', error);
        showStatus('Network error saving settings', 'error');
    }
}

// Reset settings to defaults
async function resetSettings() {
    if (!confirm('Reset all settings to default values?')) {
        return;
    }

    try {
        const response = await fetch('/api/settings/reset', {
            method: 'POST'
        });

        const data = await response.json();

        if (!response.ok) {
            showStatus(data.error || 'Error resetting settings', 'error');
            return;
        }

        // Close modal
        closeSettingsModal();

        // Show success message
        showStatus('Settings reset to defaults. Please restart the application for changes to take effect.', 'success');

    } catch (error) {
        console.error('Error resetting settings:', error);
        showStatus('Network error resetting settings', 'error');
    }
}
