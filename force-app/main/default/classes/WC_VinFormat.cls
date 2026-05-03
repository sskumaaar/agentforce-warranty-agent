/**
 * Single source of truth for the canonical Electra VIN format.
 *
 * Canonical format: 17 characters total, must start with "1ELEC", followed by
 * 12 alphanumeric characters (A-Z and 0-9). Matches industry-standard VIN
 * length (ISO 3779) with Electra Cars as the World Manufacturer Identifier.
 *
 * Use `isValid` for boolean checks and `requireValid` to enforce on user-input
 * write boundaries (e.g. submitNewClaim from the chat). DO NOT enforce on
 * read paths — existing org data may carry shorter VINs and we don't want to
 * break dealer fleet visibility for legacy records.
 */
public with sharing class WC_VinFormat {

    public static final String CANONICAL_REGEX = '^1ELEC[A-Z0-9]{12}$';
    private static final Pattern CANONICAL_PATTERN = Pattern.compile(CANONICAL_REGEX);

    public static Boolean isValid(String vin) {
        if (String.isBlank(vin)) return false;
        return CANONICAL_PATTERN.matcher(vin.toUpperCase()).matches();
    }

    public static void requireValid(String vin) {
        if (!isValid(vin)) {
            throw new AuraHandledException(
                'Invalid VIN. Electra VINs must be exactly 17 characters starting with '
                + '"1ELEC" (e.g. 1ELEC2025BOLT0001). Got: ' + (vin == null ? '(blank)' : vin)
            );
        }
    }
}