public with sharing class WC_WarrantyCheck {

    @InvocableMethod(
        label='Validate Warranty Coverage'
        description='Validates warranty coverage for a vehicle by VIN. Checks date validity, mileage limits, and coverage type. Returns whether the warranty covers the requested repair.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        try {
            Set<String> vinSet = new Set<String>();
            for (Input inp : inputs) {
                if (String.isNotBlank(inp.vinNumber)) {
                    vinSet.add(inp.vinNumber.trim());
                }
            }

            Map<String, Vehicle> vehicleByVin = new Map<String, Vehicle>();
            Set<Id> assetIdSet = new Set<Id>();
            Map<Id, String> assetIdToVin = new Map<Id, String>();

            if (!vinSet.isEmpty()) {
                for (Vehicle v : [
                    SELECT Id, Name, VehicleIdentificationNumber, AssetId, LastOdometerReading
                    FROM Vehicle
                    WHERE VehicleIdentificationNumber IN :vinSet
                ]) {
                    vehicleByVin.put(v.VehicleIdentificationNumber, v);
                    if (v.AssetId != null) {
                        assetIdSet.add(v.AssetId);
                        assetIdToVin.put(v.AssetId, v.VehicleIdentificationNumber);
                    }
                }
            }

            Map<String, List<AssetWarranty>> warrantiesByVin = new Map<String, List<AssetWarranty>>();
            if (!assetIdSet.isEmpty()) {
                for (AssetWarranty aw : [
                    SELECT Id, AssetId, WarrantyTermId,
                           WarrantyTerm.WarrantyTermName, WarrantyTerm.WarrantyType,
                           WarrantyTerm.UsageCovered, WarrantyTerm.WarrantyDuration,
                           WarrantyTerm.WarrantyUnitOfTime,
                           StartDate, EndDate,
                           LaborCovered, PartsCovered, ExpensesCovered,
                           LaborCoveredEndDate, PartsCoveredEndDate, ExpensesCoveredEndDate
                    FROM AssetWarranty
                    WHERE AssetId IN :assetIdSet
                      AND StartDate <= TODAY
                      AND EndDate >= TODAY
                    ORDER BY EndDate DESC
                ]) {
                    String vin = assetIdToVin.get(aw.AssetId);
                    if (vin != null) {
                        if (!warrantiesByVin.containsKey(vin)) {
                            warrantiesByVin.put(vin, new List<AssetWarranty>());
                        }
                        warrantiesByVin.get(vin).add(aw);
                    }
                }
            }

            for (Input inp : inputs) {
                Output out = new Output();

                if (String.isBlank(inp.vinNumber)) {
                    out.isCovered = false;
                    out.denialReason = 'VIN number is required';
                    out.message = 'VIN number is required';
                    outputs.add(out);
                    continue;
                }

                String vin = inp.vinNumber.trim();
                Vehicle v = vehicleByVin.get(vin);

                if (v == null) {
                    out.isCovered = false;
                    out.denialReason = 'Vehicle not found for VIN: ' + vin;
                    out.message = 'Vehicle not found for VIN: ' + vin;
                    outputs.add(out);
                    continue;
                }

                List<AssetWarranty> warranties = warrantiesByVin.get(vin);
                if (warranties == null || warranties.isEmpty()) {
                    out.isCovered = false;
                    out.denialReason = 'No active warranty found for this vehicle';
                    out.message = 'No active warranty coverage for VIN: ' + vin;
                    outputs.add(out);
                    continue;
                }

                AssetWarranty bestWarranty = warranties[0];
                out.warrantyId = bestWarranty.Id;
                out.warrantyTermName = bestWarranty.WarrantyTerm.WarrantyTermName;
                out.warrantyType = bestWarranty.WarrantyTerm.WarrantyType;
                out.startDate = bestWarranty.StartDate;
                out.endDate = bestWarranty.EndDate;
                out.daysRemaining = Date.today().daysBetween(bestWarranty.EndDate);
                out.laborCovered = bestWarranty.LaborCovered;
                out.partsCovered = bestWarranty.PartsCovered;
                out.mileageLimit = bestWarranty.WarrantyTerm.UsageCovered;

                if (inp.currentMileage != null && bestWarranty.WarrantyTerm.UsageCovered != null) {
                    out.mileageWithinLimit = inp.currentMileage <= bestWarranty.WarrantyTerm.UsageCovered;
                    if (!out.mileageWithinLimit) {
                        out.isCovered = false;
                        out.denialReason = 'Mileage exceeds warranty limit ('
                            + inp.currentMileage.intValue() + ' km vs '
                            + bestWarranty.WarrantyTerm.UsageCovered + ' km limit)';
                        out.message = out.denialReason;
                        outputs.add(out);
                        continue;
                    }
                } else {
                    out.mileageWithinLimit = true;
                }

                out.isCovered = true;
                out.message = 'Warranty active: ' + out.warrantyTermName
                    + ', expires ' + String.valueOf(out.endDate)
                    + ', ' + out.daysRemaining + ' days remaining';
                outputs.add(out);
            }
        } catch (Exception e) {
            outputs.clear();
            for (Input inp : inputs) {
                Output out = new Output();
                out.isCovered = false;
                out.message = 'Error checking warranty: ' + e.getMessage();
                outputs.add(out);
            }
        }

        return outputs;
    }

    public class Input {
        @InvocableVariable(required=true label='VIN Number'
            description='17-character VIN of the vehicle to check warranty for')
        public String vinNumber;

        @InvocableVariable(label='Current Mileage'
            description='Current odometer reading in km (optional, used for mileage validation)')
        public Decimal currentMileage;

        @InvocableVariable(label='Part Category'
            description='Category of the part needing repair (e.g. Powertrain, Body, Electrical)')
        public String partCategory;
    }

    public class Output {
        @InvocableVariable(label='Is Covered' description='True if the vehicle has valid warranty coverage')
        public Boolean isCovered;

        @InvocableVariable(label='Warranty Id' description='Salesforce ID of the matching AssetWarranty record')
        public String warrantyId;

        @InvocableVariable(label='Warranty Term Name' description='Name of the warranty term')
        public String warrantyTermName;

        @InvocableVariable(label='Warranty Type' description='Type of warranty coverage')
        public String warrantyType;

        @InvocableVariable(label='Start Date' description='Warranty start date')
        public Date startDate;

        @InvocableVariable(label='End Date' description='Warranty end date')
        public Date endDate;

        @InvocableVariable(label='Days Remaining' description='Number of days until warranty expiration')
        public Integer daysRemaining;

        @InvocableVariable(label='Mileage Limit' description='Maximum mileage covered by warranty (km)')
        public Decimal mileageLimit;

        @InvocableVariable(label='Mileage Within Limit' description='True if current mileage is within warranty mileage limit')
        public Boolean mileageWithinLimit;

        @InvocableVariable(label='Labor Covered' description='Whether labor costs are covered')
        public Decimal laborCovered;

        @InvocableVariable(label='Parts Covered' description='Whether parts costs are covered')
        public Decimal partsCovered;

        @InvocableVariable(label='Denial Reason' description='If not covered, explains why')
        public String denialReason;

        @InvocableVariable(label='Message' description='Human-readable summary of warranty status')
        public String message;
    }
}