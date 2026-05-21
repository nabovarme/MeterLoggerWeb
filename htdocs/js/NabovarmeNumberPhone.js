class NabovarmeNumberPhone {
	constructor(input) {
		if (input === null || input === undefined) {
			this.obj = null;
			return;
		}

		let cleaned = String(input);

		// Strip leading/trailing whitespace and inner spaces/hyphens
		cleaned = cleaned.trim().replace(/[- ]/g, '');

		// 1. Standardize 00 prefix into international '+' formatting
		if (/^00(\d+)/.test(cleaned)) {
			cleaned = '+' + cleaned.match(/^00(\d+)/)[1];
		}
		// 2. If it is exactly 8 digits, safely assume it's a local Danish number
		else if (/^\d{8}$/.test(cleaned)) {
			cleaned = '+45' + cleaned;
		}

		try {
			// libphonenumber-js naturally handles numbers starting with '+'
			if (typeof libphonenumber !== 'undefined') {
				const parsed = libphonenumber.parsePhoneNumber(cleaned);
				if (parsed && parsed.isValid()) {
					this.obj = parsed;
					return;
				}
			}
		} catch (error) {
			// Parsing exceptions are safely caught to mimic Perl's eval
		}

		this.obj = null;
	}

	// Factory method mimicking Perl's Nabovarme::Number::Phone->new($input)
	static new(input) {
		const instance = new NabovarmeNumberPhone(input);
		return instance.obj ? instance : undefined;
	}

	isValid() {
		return this.obj ? this.obj.isValid() : false;
	}

	country() {
		// Returns the 2-letter country code (e.g., 'DK')
		return this.obj ? this.obj.country : undefined;
	}

	// ✔ E.164 = library canonical output
	e164() {
		return this.obj ? this.obj.number : undefined;
	}

	// ✔ DB format (fully normalized, no double country codes)
	compact() {
		if (!this.obj) return undefined;

		// libphonenumber-js .number natively returns E.164 (e.g., "+4520291699")
		let raw = this.obj.number;
		if (!raw) return undefined;

		// Clean up any remaining formatting artifacts from the underlying library representation
		raw = raw.replace(/[^\d+]/g, ''); // Keep only digits and the leading plus symbol

		// If the library output lacks a leading '+', safely prepend it
		if (!raw.startsWith('+')) {
			raw = '+' + raw;
		}

		return raw;
	}

	// ✔ Standard international format with 00 prefix instead of +
	international() {
		const val = this.compact();
		if (!val) return undefined;

		return val.replace(/^\+/, '00');
	}
}