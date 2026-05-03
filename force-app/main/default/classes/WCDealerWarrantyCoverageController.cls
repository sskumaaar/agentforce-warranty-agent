/**
 * WCDealerWarrantyCoverageController
 * Returns warranty card data for the Dealer Portal Warranty Coverage LWC.
 * Uses corrected field names per FIELD_NAME_CORRECTIONS_CRITICAL.md:
 *   - AssetWarranty has NO Status field — active status derived from StartDate/EndDate
 *   - Vehicle -> Asset -> AssetWarranty (2-step query chain)
 *   - Vehicle fields: VehicleIdentificationNumber, MakeName, ModelName, ModelYear, LastOdometerReading
 */
public with sharing class WCDealerWarrantyCoverageController {

    public class WarrantyCard {
        @AuraEnabled public String  vin             { get; set; }
        @AuraEnabled public String  vehicleLabel    { get; set; }
        @AuraEnabled public String  statusLabel     { get; set; }
        @AuraEnabled public String  statusType      { get; set; }  // active / expiring / expired
        @AuraEnabled public String  expiryDisplay   { get; set; }
        @AuraEnabled public Integer daysUntilExpiry { get; set; }
        @AuraEnabled public Integer progressPct     { get; set; }
        @AuraEnabled public String  odometerDisplay { get; set; }
        @AuraEnabled public String  warrantyType    { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<WarrantyCard> getWarrantyCards() {

        // ── Step 1: Query Vehicles (limit 10), retrieve AssetId for chain ──────
        List<Vehicle> vehicles = [
            SELECT Id, Name, VehicleIdentificationNumber, AssetId,
                   MakeName, ModelName, ModelYear, LastOdometerReading
            FROM Vehicle
            WHERE AssetId != null
            WITH SECURITY_ENFORCED
            LIMIT 10
        ];

        if (vehicles.isEmpty()) {
            return new List<WarrantyCard>();
        }

        // Build set of Asset Ids
        Set<Id> assetIds = new Set<Id>();
        Map<Id, Vehicle> assetToVehicle = new Map<Id, Vehicle>();
        for (Vehicle v : vehicles) {
            assetIds.add(v.AssetId);
            assetToVehicle.put(v.AssetId, v);
        }

        // ── Step 2: Query AssetWarranty by AssetId, order expiring soonest first ─
        List<AssetWarranty> warranties = [
            SELECT Id, AssetId, StartDate, EndDate, WarrantyType,
                   LaborCovered, PartsCovered, ExpensesCovered
            FROM AssetWarranty
            WHERE AssetId IN :assetIds
            WITH SECURITY_ENFORCED
            ORDER BY EndDate ASC
            LIMIT 10
        ];

        Date today = Date.today();

        List<WarrantyCard> cards = new List<WarrantyCard>();

        for (AssetWarranty aw : warranties) {
            Vehicle veh = assetToVehicle.get(aw.AssetId);
            if (veh == null) {
                continue;
            }

            WarrantyCard card = new WarrantyCard();

            // ── VIN ──────────────────────────────────────────────────────────
            card.vin = String.isNotBlank(veh.VehicleIdentificationNumber)
                       ? veh.VehicleIdentificationNumber
                       : veh.Name;

            // ── Vehicle Label: "2022 Electra Bolt" ───────────────────────────
            String yearStr  = veh.ModelYear != null ? String.valueOf(veh.ModelYear) : '';
            String makeStr  = String.isNotBlank(veh.MakeName)  ? veh.MakeName  : '';
            String modelStr = String.isNotBlank(veh.ModelName) ? veh.ModelName : '';
            card.vehicleLabel = (yearStr + ' ' + makeStr + ' ' + modelStr).trim();
            if (String.isBlank(card.vehicleLabel)) {
                card.vehicleLabel = veh.Name;
            }

            // ── Status derivation (no Status field on AssetWarranty) ─────────
            Integer daysLeft = today.daysBetween(aw.EndDate);   // negative if past
            card.daysUntilExpiry = daysLeft;

            if (aw.EndDate < today) {
                card.statusType  = 'expired';
                card.statusLabel = '\u2715 Expired';            // ✕
            } else if (daysLeft <= 30) {
                card.statusType  = 'expiring';
                card.statusLabel = '\u26A0 Expiring Soon';      // ⚠
            } else {
                card.statusType  = 'active';
                card.statusLabel = '\u25CF Active';             // ●
            }

            // ── Expiry display: "Expires Mar 2028" ───────────────────────────
            card.expiryDisplay = formatMonthYear(aw.EndDate, aw.EndDate < today);

            // ── Progress percentage: elapsed portion of warranty period ──────
            if (aw.StartDate != null && aw.EndDate != null && aw.StartDate < aw.EndDate) {
                Integer totalDays   = aw.StartDate.daysBetween(aw.EndDate);
                Integer elapsedDays = aw.StartDate.daysBetween(today);
                if (totalDays > 0) {
                    Integer pct = (Integer) Math.floor(((Decimal) elapsedDays / totalDays) * 100);
                    card.progressPct = Math.max(0, Math.min(100, pct));
                } else {
                    card.progressPct = 100;
                }
            } else {
                card.progressPct = 0;
            }

            // ── Odometer: "45,200 km" ─────────────────────────────────────────
            if (veh.LastOdometerReading != null) {
                Long odom = (Long) veh.LastOdometerReading;
                card.odometerDisplay = formatNumber(odom) + ' km';
            } else {
                card.odometerDisplay = '-- km';
            }

            // ── Warranty type ─────────────────────────────────────────────────
            card.warrantyType = String.isNotBlank(aw.WarrantyType) ? aw.WarrantyType : 'Standard';

            cards.add(card);
        }

        return cards;
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static final String[] MONTHS = new String[]{
        'Jan','Feb','Mar','Apr','May','Jun',
        'Jul','Aug','Sep','Oct','Nov','Dec'
    };

    private static String formatMonthYear(Date d, Boolean expired) {
        if (d == null) return '';
        String prefix = expired ? 'Expired ' : 'Expires ';
        return prefix + MONTHS[d.month() - 1] + ' ' + d.year();
    }

    private static String formatNumber(Long n) {
        // Insert commas: e.g. 45200 -> "45,200"
        String raw = String.valueOf(Math.abs(n));
        String result = '';
        Integer len = raw.length();
        for (Integer i = 0; i < len; i++) {
            if (i > 0 && Math.mod(len - i, 3) == 0) {
                result += ',';
            }
            result += raw.substring(i, i + 1);
        }
        return result;
    }
}