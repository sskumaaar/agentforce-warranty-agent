/**
 * WC_P16_DiagnosticTest — runs every WC_DealerServicePortalController @AuraEnabled
 * method as the real dealer user, so we know exactly which one fails and why.
 */
@isTest(SeeAllData=true)
private class WC_P16_DiagnosticTest {

    @isTest
    static void diagnoseAllMethods() {
        User dealer = [SELECT Id, Username FROM User
                       WHERE Username = 'vikram.joshi@mumbaielectra.in.demo' LIMIT 1];

        String results = '\n=== P16 Full Method Diagnostic ===\n';

        System.runAs(dealer) {
            // M1: getDealerPortalData
            try {
                Map<String, Object> data = WC_DealerServicePortalController.getDealerPortalData();
                Integer claimsCount = ((List<Object>)data.get('claims')).size();
                results += 'M1 getDealerPortalData: PASS claims=' + claimsCount + '\n';
            } catch (Exception e) { results += 'M1 FAIL: ' + e.getTypeName() + ': ' + e.getMessage() + '\n'; }

            // M2: getDealerVehicles
            try {
                List<Object> vehicles = WC_DealerServicePortalController.getDealerVehicles();
                results += 'M2 getDealerVehicles: PASS count=' + vehicles.size() + '\n';
            } catch (Exception e) { results += 'M2 FAIL: ' + e.getTypeName() + ': ' + e.getMessage() + '\n'; }

            // M3: getPerformanceMetrics
            try {
                Map<String, Object> m = WC_DealerServicePortalController.getPerformanceMetrics();
                results += 'M3 getPerformanceMetrics: PASS keys=' + m.keySet() + '\n';
            } catch (Exception e) { results += 'M3 FAIL: ' + e.getTypeName() + ': ' + e.getMessage() + '\n'; }

            // M4: getClaimDetail with first dealer claim
            try {
                List<Claim> firstClaim = [SELECT Id FROM Claim WHERE AccountId = '001bm00001igNZSAA2' LIMIT 1];
                if (firstClaim.isEmpty()) {
                    results += 'M4 getClaimDetail: SKIP (no claims)\n';
                } else {
                    Object detail = WC_DealerServicePortalController.getClaimDetail(firstClaim[0].Id);
                    results += 'M4 getClaimDetail: PASS for ' + firstClaim[0].Id + '\n';
                }
            } catch (Exception e) { results += 'M4 FAIL: ' + e.getTypeName() + ': ' + e.getMessage() + '\n'; }

            // M5: lookupVIN with first dealer VIN
            try {
                List<Vehicle> firstVehicle = [SELECT VehicleIdentificationNumber FROM Vehicle
                                              WHERE AssetId IN (SELECT Id FROM Asset WHERE AccountId = '001bm00001igNZSAA2')
                                              LIMIT 1];
                if (firstVehicle.isEmpty()) {
                    results += 'M5 lookupVIN: SKIP (no vehicles)\n';
                } else {
                    Object v = WC_DealerServicePortalController.lookupVIN(firstVehicle[0].VehicleIdentificationNumber);
                    results += 'M5 lookupVIN: PASS for ' + firstVehicle[0].VehicleIdentificationNumber + '\n';
                }
            } catch (Exception e) { results += 'M5 FAIL: ' + e.getTypeName() + ': ' + e.getMessage() + '\n'; }

            // P-objects: per-object accessibility for Asset, Vehicle, AssetWarranty, ContentDocumentLink
            for (String objName : new List<String>{'Asset','Vehicle','AssetWarranty','ContentDocumentLink'}) {
                try {
                    Schema.DescribeSObjectResult d = Schema.getGlobalDescribe().get(objName).getDescribe();
                    results += 'P-obj ' + objName + ': accessible=' + d.isAccessible() + '\n';
                } catch (Exception e) { results += 'P-obj ' + objName + ': ERROR ' + e.getMessage() + '\n'; }
            }

            // Asset count visible
            try {
                Integer assetN = [SELECT COUNT() FROM Asset WHERE AccountId = '001bm00001igNZSAA2'];
                results += 'Asset count visible: ' + assetN + '\n';
            } catch (Exception e) { results += 'Asset count FAIL: ' + e.getMessage() + '\n'; }
            try {
                Integer awN = [SELECT COUNT() FROM AssetWarranty WHERE Asset.AccountId = '001bm00001igNZSAA2'];
                results += 'AssetWarranty count visible: ' + awN + '\n';
            } catch (Exception e) { results += 'AW count FAIL: ' + e.getMessage() + '\n'; }
            try {
                Integer vN = [SELECT COUNT() FROM Vehicle WHERE AssetId IN (SELECT Id FROM Asset WHERE AccountId = '001bm00001igNZSAA2')];
                results += 'Vehicle count visible: ' + vN + '\n';
            } catch (Exception e) { results += 'Vehicle count FAIL: ' + e.getMessage() + '\n'; }
        }

        System.assert(false, results);
    }
}