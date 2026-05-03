/**
 * Cross-dealer-aware: this class runs `without sharing` because dealer users
 * (Customer Community Plus) cannot see vehicles owned by OTHER dealers under
 * default sharing. Cross-dealer warranty service is an authorized business
 * scenario — any Electra dealer can service any Electra VIN — so the elevated
 * read is intentional. We expose only Vehicle + warranty + owning-dealer name
 * (no PII / no financial fields).
 */
public without sharing class WC_VINLookup {

    @InvocableMethod(
        label='Look Up Vehicle by VIN'
        description='Looks up a vehicle record by its 17-character VIN. Returns vehicle details including model, color, odometer, and active warranty status.'
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
                    SELECT Id, Name, VehicleIdentificationNumber, AssetId,
                           CurrentOwnerId, MakeName, ModelName, ModelYear,
                           ExteriorColor, LastOdometerReading, IsRecallOpen, Status
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

            // Owning dealer (Asset.AccountId) — used so the agent can tell the
            // user which dealer the vehicle is registered to, and detect a
            // cross-dealer service scenario.
            Map<String, Id>     vinToOwnerAcctId   = new Map<String, Id>();
            Map<String, String> vinToOwnerAcctName = new Map<String, String>();
            if (!assetIdSet.isEmpty()) {
                for (Asset a : [
                    SELECT Id, AccountId, Account.Name FROM Asset WHERE Id IN :assetIdSet
                ]) {
                    String vin = assetIdToVin.get(a.Id);
                    if (vin != null && a.AccountId != null) {
                        vinToOwnerAcctId.put(vin, a.AccountId);
                        if (a.Account != null) vinToOwnerAcctName.put(vin, a.Account.Name);
                    }
                }
            }
            // Running user's dealer Account (servicing dealer)
            Id servicingAcctId = null;
            try {
                List<User> users = [SELECT ContactId, AccountId FROM User
                                    WHERE Id = :UserInfo.getUserId() LIMIT 1];
                if (!users.isEmpty()) {
                    if (users[0].AccountId != null) servicingAcctId = users[0].AccountId;
                    else if (users[0].ContactId != null) {
                        List<Contact> cs = [SELECT AccountId FROM Contact
                                            WHERE Id = :users[0].ContactId LIMIT 1];
                        if (!cs.isEmpty()) servicingAcctId = cs[0].AccountId;
                    }
                }
            } catch (Exception ignore) {}

            Map<String, AssetWarranty> warrantyByVin = new Map<String, AssetWarranty>();
            if (!assetIdSet.isEmpty()) {
                for (AssetWarranty aw : [
                    SELECT Id, AssetId, WarrantyTermId,
                           WarrantyTerm.WarrantyTermName, WarrantyTerm.WarrantyType,
                           WarrantyTerm.UsageCovered, WarrantyTerm.WarrantyDuration,
                           WarrantyTerm.WarrantyUnitOfTime,
                           StartDate, EndDate, LaborCovered, PartsCovered, ExpensesCovered
                    FROM AssetWarranty
                    WHERE AssetId IN :assetIdSet
                      AND StartDate <= TODAY
                      AND EndDate >= TODAY
                    ORDER BY EndDate DESC
                ]) {
                    String vin = assetIdToVin.get(aw.AssetId);
                    if (vin != null && !warrantyByVin.containsKey(vin)) {
                        warrantyByVin.put(vin, aw);
                    }
                }
            }

            for (Input inp : inputs) {
                Output out = new Output();

                if (String.isBlank(inp.vinNumber)) {
                    out.vehicleFound = false;
                    out.message = 'VIN number is required';
                    outputs.add(out);
                    continue;
                }

                String vin = inp.vinNumber.trim();
                Vehicle v = vehicleByVin.get(vin);

                if (v == null) {
                    out.vehicleFound = false;
                    out.warrantyStatus = 'Not Found';
                    out.message = 'No vehicle found for VIN: ' + vin;
                    outputs.add(out);
                    continue;
                }

                out.vehicleFound = true;
                out.vehicleId = v.Id;
                out.vehicleName = v.Name;
                out.assetId = v.AssetId;
                out.make = v.MakeName;
                out.model = v.ModelName;
                out.modelYear = v.ModelYear;
                out.exteriorColor = v.ExteriorColor;
                out.odometerReading = v.LastOdometerReading;
                out.ownerAccountId = v.CurrentOwnerId;
                out.hasOpenRecall = v.IsRecallOpen == true;

                AssetWarranty aw = warrantyByVin.get(vin);
                if (aw != null) {
                    out.warrantyStatus = 'Active';
                    out.warrantyType = aw.WarrantyTerm.WarrantyTermName
                        + ' (' + aw.WarrantyTerm.WarrantyType + ')';
                    out.warrantyExpiryDate = aw.EndDate;
                } else {
                    out.warrantyStatus = 'Expired';
                }

                // Cross-dealer info — surface so the agent can say "registered
                // to <X>; cross-dealer service is allowed for any Electra VIN".
                Id ownerAcctId      = vinToOwnerAcctId.get(vin);
                out.ownerDealerName = vinToOwnerAcctName.get(vin);
                out.crossDealer     = (ownerAcctId != null && servicingAcctId != null
                                       && ownerAcctId != servicingAcctId);

                out.message = 'Vehicle found: ' + v.Name;
                outputs.add(out);
            }
        } catch (Exception e) {
            outputs.clear();
            for (Input inp : inputs) {
                Output out = new Output();
                out.vehicleFound = false;
                out.message = 'Error looking up vehicle: ' + e.getMessage();
                outputs.add(out);
            }
        }

        return outputs;
    }

    public class Input {
        @InvocableVariable(required=true label='VIN Number'
            description='The 17-character Vehicle Identification Number to look up')
        public String vinNumber;
    }

    public class Output {
        @InvocableVariable(label='Vehicle Found' description='True if a vehicle with this VIN exists in the system')
        public Boolean vehicleFound;

        @InvocableVariable(label='Vehicle Id' description='Salesforce record ID of the Vehicle')
        public String vehicleId;

        @InvocableVariable(label='Vehicle Name' description='Display name of the vehicle')
        public String vehicleName;

        @InvocableVariable(label='Asset Id' description='Salesforce record ID of the linked Asset record')
        public String assetId;

        @InvocableVariable(label='Make' description='Vehicle make')
        public String make;

        @InvocableVariable(label='Model' description='Vehicle model')
        public String model;

        @InvocableVariable(label='Model Year' description='Manufacturing year of the vehicle')
        public String modelYear;

        @InvocableVariable(label='Exterior Color' description='Exterior color of the vehicle')
        public String exteriorColor;

        @InvocableVariable(label='Odometer Reading' description='Last recorded odometer reading in km')
        public Decimal odometerReading;

        @InvocableVariable(label='Owner Account Id' description='ID of the current owner Account')
        public String ownerAccountId;

        @InvocableVariable(label='Warranty Status' description='Active, Expired, or Not Found')
        public String warrantyStatus;

        @InvocableVariable(label='Warranty Type' description='Type of active warranty')
        public String warrantyType;

        @InvocableVariable(label='Warranty Expiry Date' description='End date of the active warranty')
        public Date warrantyExpiryDate;

        @InvocableVariable(label='Has Open Recall' description='Whether the vehicle has an open recall')
        public Boolean hasOpenRecall;

        @InvocableVariable(label='Owner Dealer Name'
            description='Name of the Electra dealer the vehicle is registered to. Helps the agent explain cross-dealer service to the user.')
        public String ownerDealerName;

        @InvocableVariable(label='Cross Dealer'
            description='True if the vehicle is registered to a dealer different from the dealer currently logged in. Any Electra dealer may still service / file warranty for any Electra VIN.')
        public Boolean crossDealer;

        @InvocableVariable(label='Message' description='Status message or error details')
        public String message;
    }
}