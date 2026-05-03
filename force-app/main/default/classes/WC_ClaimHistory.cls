// Read-only history lookup. Runs without sharing so all approver users see full history.
public without sharing class WC_ClaimHistory {

    public class HistoryRequest {
        @InvocableVariable(required=true label='Lookup Type' description='REQUIRED. Must be exactly "dealer" (for dealer/account history) or "vehicle" (for VIN history). Pick "dealer" when user asks about a dealer name. Pick "vehicle" when user asks about a VIN.')
        public String lookupType;

        @InvocableVariable(label='VIN' description='17-char Vehicle Identification Number — REQUIRED when lookupType="vehicle". Example: 1ELEC2024BOLT003.')
        public String vin;

        @InvocableVariable(label='Account Id' description='Salesforce Account.Id (15/18-char) of the dealer when lookupType="dealer". Use Dealer Name instead if user provided a name string.')
        public String accountId;

        @InvocableVariable(label='Dealer Name' description='Dealer Account.Name when lookupType="dealer". Examples: "Pune Electra Service Center", "Bangalore Electra Motors". Pass the dealer name exactly as the user said it. The action will resolve it to the Account.Id internally.')
        public String dealerName;

        @InvocableVariable(label='Days Back' description='Lookback window in days. Default 90, max 730. Examples: 30 for "last month", 90 for "last quarter", 365 for "last year".')
        public Integer daysBack;
    }

    public class HistoryResponse {
        // ONLY this field is exposed to the agent.
        @InvocableVariable(label='Response' description='Formatted plain-text claim history. Present verbatim.')
        public String message;

        // Internal-only.
        public Integer totalClaims;
        public String claims;
        public Decimal totalAmount;
        public Decimal approvalRate;
        public String errorMessage;
    }

    @InvocableMethod(
        label='View Claim History'
        description='Historical Electra Cars warranty claims by dealer account or vehicle VIN'
    )
    public static List<HistoryResponse> loadHistory(List<HistoryRequest> requests) {
        List<HistoryResponse> results = new List<HistoryResponse>();
        if (requests == null) {
            return results;
        }

        for (HistoryRequest req : requests) {
            HistoryResponse hr = new HistoryResponse();
            Integer days = (req.daysBack != null && req.daysBack > 0) ? Math.min(req.daysBack, 730) : 90;
            Date cutoff = Date.today().addDays(-days);
            String lt = String.isBlank(req.lookupType) ? '' : req.lookupType.trim().toLowerCase();

            try {
                if (lt == 'dealer') {
                    loadByDealer(req.accountId, req.dealerName, cutoff, hr);
                } else if (lt == 'vehicle') {
                    loadByVin(req.vin, cutoff, hr);
                } else {
                    hr.errorMessage = 'lookupType must be vehicle or dealer for Electra Cars claim history.';
                    hr.message = '⚠️ Pass lookupType=dealer or vehicle.';
                }
            } catch (Exception e) {
                hr.errorMessage = e.getMessage();
                hr.message = '⚠️ Claim history failed: ' + e.getMessage();
            }
            results.add(hr);
        }
        return results;
    }

    private static void loadByDealer(String accountId, String dealerName, Date cutoff, HistoryResponse hr) {
        Id aid;
        if (String.isNotBlank(accountId)) {
            try { aid = Id.valueOf(accountId.trim()); } catch (Exception e) { aid = null; }
        }
        if (aid == null && String.isNotBlank(dealerName)) {
            List<Account> dealers = [SELECT Id FROM Account WHERE Name = :dealerName.trim() LIMIT 1];
            if (!dealers.isEmpty()) { aid = dealers[0].Id; }
        }
        if (aid == null) {
            hr.errorMessage = 'Account Id or Dealer Name is required for dealer history.';
            return;
        }
        List<Claim> claims = [
            SELECT Name, Status, StatusCode, EstimatedAmount, InitiationDate, FinalizedDate
            FROM Claim
            WHERE AccountId = :aid AND InitiationDate >= :cutoff
            ORDER BY InitiationDate DESC
            LIMIT 100
        ];
        assembleHistory(claims, hr);
    }

    private static void loadByVin(String vinValue, Date cutoff, HistoryResponse hr) {
        if (String.isBlank(vinValue)) {
            hr.errorMessage = 'VIN is required for vehicle history.';
            return;
        }
        List<Vehicle> vrows = [
            SELECT Id FROM Vehicle WHERE VehicleIdentificationNumber = :vinValue.trim() LIMIT 1
        ];
        if (vrows.isEmpty()) {
            hr.totalClaims = 0;
            hr.claims = 'No Electra Cars vehicle found for VIN.';
            return;
        }
        Id vehId = vrows[0].Id;
        Set<Id> claimIds = new Set<Id>();
        for (ClaimItem ci : [SELECT ClaimId FROM ClaimItem WHERE VehicleId = :vehId]) {
            claimIds.add(ci.ClaimId);
        }
        if (claimIds.isEmpty()) {
            hr.totalClaims = 0;
            hr.claims = 'No claims linked to this vehicle.';
            return;
        }
        List<Claim> claims = [
            SELECT Name, Status, StatusCode, EstimatedAmount, InitiationDate, FinalizedDate
            FROM Claim
            WHERE Id IN :claimIds AND InitiationDate >= :cutoff
            ORDER BY InitiationDate DESC
            LIMIT 100
        ];
        assembleHistory(claims, hr);
    }

    private static void assembleHistory(List<Claim> claims, HistoryResponse hr) {
        hr.totalClaims = claims.size();
        Decimal sumAmt = 0;
        Integer approved = 0;
        Integer decided = 0;
        List<String> lines = new List<String>();

        for (Claim c : claims) {
            if (c.EstimatedAmount != null) {
                sumAmt += c.EstimatedAmount;
            }
            if (c.Status == 'Approved' || c.StatusCode == 'Approved') {
                approved++;
                decided++;
            } else if (c.Status == 'Denied' || c.StatusCode == 'Denied') {
                decided++;
            }
            lines.add(
                c.Name + ' | ' + String.valueOf(c.Status) + ' | $' +
                (c.EstimatedAmount != null ? c.EstimatedAmount.setScale(0).toPlainString() : '0') +
                ' | ' + String.valueOf(c.InitiationDate)
            );
        }

        hr.totalAmount = sumAmt;
        hr.approvalRate = (decided > 0)
            ? ((Decimal)(100 * approved) / (Decimal) decided).setScale(2)
            : null;
        hr.claims = String.join(lines, '\n');

        // Build the rich plain-text message for the agent.
        List<String> ml = new List<String>();
        ml.add('📜 Claim History (' + claims.size() + ' claim' + (claims.size() == 1 ? '' : 's') + ')');
        ml.add('━━━━━━━━━━━━━━━━━━━━━━━');
        ml.add('Total Amount: $' + sumAmt.setScale(2).toPlainString());
        if (hr.approvalRate != null) {
            ml.add('Approval Rate: ' + hr.approvalRate + '% (' + approved + ' of ' + decided + ' decided)');
        }
        ml.add('');
        if (claims.isEmpty()) {
            ml.add('(no claims in window)');
        } else {
            ml.add('Claims:');
            for (String line : lines) { ml.add('  ' + line); }
        }
        hr.message = String.join(ml, '\n');
    }
}