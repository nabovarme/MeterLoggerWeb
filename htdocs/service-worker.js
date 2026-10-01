// Force the new service worker to activate immediately upon downloading
self.addEventListener('install', function(event) {
	self.skipWaiting();
});

// Take control of all open tabs as soon as it activates
self.addEventListener('activate', function(event) {
	event.waitUntil(clients.claim());
});

self.addEventListener('push', function(event) {
	if (!event.data) return;

	let payload = {};
	try {
		payload = event.data.json();
	} catch (e) {
		payload = { title: 'MeterLogger Alert', body: event.data.text() };
	}

	const tag = payload.tag || 'meter-alarm-default';

	const options = {
		body: payload.body || 'New alert from MeterLogger',
		icon: payload.icon || '/android-chrome-192x192.png',
		badge: payload.badge || '/favicon-32x32.png',
		image: payload.image,
		tag: tag, // Automatically replaces previous active notifications with this tag
		renotify: payload.renotify !== undefined ? payload.renotify : true,
		// Safari fix: Ensure strict boolean to prevent background assertion leaks
		requireInteraction: payload.requireInteraction === true,
		vibrate: payload.vibrate || [100, 50, 100],
		data: {
			url: payload.url || '/',
			actionUrls: {}
		}
	};

	// Map action buttons securely
	if (payload.actions && Array.isArray(payload.actions)) {
		options.actions = payload.actions.map(actionObj => {
			if (actionObj.url) {
				options.data.actionUrls[actionObj.action] = actionObj.url;
			}
			return {
				action: actionObj.action,
				title: actionObj.title,
				icon: actionObj.icon
			};
		});
	}

	// Wait for the notification to show, and catch any OS-level rejections 
	// to prevent the worker from crashing if Safari blocks it.
	event.waitUntil(
		self.registration.showNotification(payload.title || 'MeterLogger', options)
		.catch(err => console.error('Failed to show notification:', err))
	);
});

self.addEventListener('notificationclick', function(event) {
	event.notification.close();

	// Default to the main notification URL
	let targetUrl = event.notification.data ? event.notification.data.url : '/';

	// If the user clicked a specific action button, override the targetUrl
	if (event.action && event.notification.data && event.notification.data.actionUrls) {
		if (event.notification.data.actionUrls[event.action]) {
			targetUrl = event.notification.data.actionUrls[event.action];
		}
	}

	event.waitUntil(
		clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(clientList) {
			// Safely parse the target URL so we can compare exact paths (fixes the '/' bug)
			const targetPath = new URL(targetUrl, self.location.origin).pathname;

			for (let i = 0; i < clientList.length; i++) {
				const client = clientList[i];
				
				try {
					const clientPath = new URL(client.url).pathname;
					// Focus the existing tab if it's already open to the exact intended path
					if (clientPath === targetPath && 'focus' in client) {
						return client.focus();
					}
				} catch (e) {
					console.warn('Could not parse client URL:', client.url);
				}
			}
			
			// Otherwise, open a new window/tab
			if (clients.openWindow) {
				return clients.openWindow(targetUrl);
			}
		})
	);
});
