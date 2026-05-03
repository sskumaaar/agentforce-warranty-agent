/**
 * Cross-dealer-aware: runs `without sharing` so a dealer (e.g. Mumbai) can
 * file a claim on a VIN registered to a different dealer (e.g. Bangalore).
 * Default sharing would block the Vehicle / Asset / Account reads needed to
 * detect the cross-dealer scenario and prefix the Summary correctly. The
 * Claim record is still attributed to the SERVICING dealer's AccountId via
 * resolveRunningDealerAccountId(), so attribution + visibility is unchanged.
 */
public without sharing class WC_CreateClaim {

    @InvocableMethod(
        label='Create Warranty Claim'
        description='Creates a new warranty claim with associated claim items. Requires valid VIN, part code, and dealer context. Returns the claim number and confirmation.'
    )
    public static List<Output> execute(List<Input> inputs) {
        List<Output> outputs = new List<Output>();
        if (inputs == null || inputs.isEmpty()) {
            return outputs;
        }

        try {
            Set<String> vinSet = new Set<String>();
            Set<String> partCodeSet = new Set<String>();
            for (Input inp : inputs) {
                if (String.isNotBlank(inp.vinNumber)) {
                    vinSet.add(inp.vinNumber.trim());
                }
                if (String.isNotBlank(inp.partCode)) {
                    partCodeSet.add(inp.partCode.trim());
                }
            }

            Map<String, Vehicle> vehicleByVin = new Map<String, Vehicle>();
            Set<Id> assetIdSet = new Set<Id>();
            if (!vinSet.isEmpty()) {
                for (Vehicle v : [
                    SELECT Id, Name, VehicleIdentificationNumber, AssetId, CurrentOwnerId
                    FROM Vehicle
                    WHERE VehicleIdentificationNumber IN :vinSet
                ]) {
                    vehicleByVin.put(v.VehicleIdentificationNumber, v);
                    if (v.AssetId != null) {
                        assetIdSet.add(v.AssetId);
                    }
                }
            }

            // Resolve owning-dealer Account for each VIN (Vehicle.AssetId →
            // Asset.AccountId). Used to detect cross-dealer service.
            Map<Id, Id>     assetToOwnerAcct = new Map<Id, Id>();
            Map<Id, String> assetToOwnerName = new Map<Id, String>();
            if (!assetIdSet.isEmpty()) {
                for (Asset a : [
                    SELECT Id, AccountId, Account.Name FROM Asset WHERE Id IN :assetIdSet
                ]) {
                    if (a.AccountId != null) {
                        assetToOwnerAcct.put(a.Id, a.AccountId);
                        if (a.Account != null) assetToOwnerName.put(a.Id, a.Account.Name);
                    }
                }
            }

            // Resolve the SERVICING dealer = the running user's Account (or
            // their Contact's Account for Customer Community Plus users). This
            // is the dealer who is filing the claim, regardless of who sold the
            // vehicle. Falls back gracefully when used outside a dealer session
            // (e.g., admin-driven test runs).
            Id runningDealerAccId = resolveRunningDealerAccountId();

            Map<String, Product2> partByCode = new Map<String, Product2>();
            if (!partCodeSet.isEmpty()) {
                for (Product2 p : [
                    SELECT Id, Name, ProductCode, Family
                    FROM Product2
                    WHERE ProductCode IN :partCodeSet AND IsActive = true
                ]) {
                    partByCode.put(p.ProductCode, p);
                }
            }

            Set<Id> assetsWithWarranty = new Set<Id>();
            if (!assetIdSet.isEmpty()) {
                for (AssetWarranty aw : [
                    SELECT AssetId
                    FROM AssetWarranty
                    WHERE AssetId IN :assetIdSet
                      AND StartDate <= TODAY
                      AND EndDate >= TODAY
                ]) {
                    assetsWithWarranty.add(aw.AssetId);
                }
            }

            List<Claim> claimsToInsert = new List<Claim>();
            Map<Integer, Integer> claimIdxToOutputIdx = new Map<Integer, Integer>();
            Map<Integer, Input> claimIdxToInput = new Map<Integer, Input>();
            Map<Integer, Vehicle> claimIdxToVehicle = new Map<Integer, Vehicle>();
            Map<Integer, Product2> claimIdxToPart = new Map<Integer, Product2>();

            for (Integer i = 0; i < inputs.size(); i++) {
                Input inp = inputs[i];
                Output out = new Output();
                outputs.add(out);

                if (String.isBlank(inp.vinNumber)) {
                    out.success = false;
                    out.message = 'VIN number is required to create a warranty claim';
                    continue;
                }

                String vin = inp.vinNumber.trim();
                Vehicle v = vehicleByVin.get(vin);
                if (v == null) {
                    out.success = false;
                    out.message = 'No vehicle found for VIN: ' + vin;
                    continue;
                }

                Product2 part = String.isNotBlank(inp.partCode)
                    ? partByCode.get(inp.partCode.trim()) : null;
                if (String.isNotBlank(inp.partCode) && part == null) {
                    out.success = false;
                    out.message = 'Part code not found in catalog: ' + inp.partCode;
                    continue;
                }

                // Determine the SERVICING dealer's Account (Claim.AccountId).
                // Priority: explicit input → running user's dealer Account →
                // owning-dealer fallback. This fixes a long-standing bug where
                // we silently used Vehicle.CurrentOwnerId, which is the asset
                // OWNER (originating dealer or customer) — not the dealer who
                // is filing the claim. For cross-dealer service those differ.
                Id servicingAcct = String.isNotBlank(inp.dealerAccountId)
                    ? (Id) inp.dealerAccountId
                    : (runningDealerAccId != null
                        ? runningDealerAccId
                        : (v.AssetId != null && assetToOwnerAcct.containsKey(v.AssetId)
                            ? assetToOwnerAcct.get(v.AssetId)
                            : v.CurrentOwnerId));

                // Cross-dealer detection: vehicle is registered to dealer A,
                // claim is being filed by dealer B. Per Electra's network
                // policy any authorized dealer may file a warranty claim.
                Id      ownerAcctId   = v.AssetId != null ? assetToOwnerAcct.get(v.AssetId) : null;
                String  ownerAcctName = v.AssetId != null ? assetToOwnerName.get(v.AssetId) : null;
                Boolean isCrossDealer = (ownerAcctId != null && servicingAcct != null
                                         && ownerAcctId != servicingAcct);

                Claim c = new Claim();
                c.Name = WC_ClaimNameGenerator.next();
                c.AccountId = servicingAcct;
                // Prefix Summary with cross-dealer context so the approver and
                // the originating dealer have full visibility without needing a
                // new custom field.
                c.Summary = isCrossDealer && String.isNotBlank(ownerAcctName)
                    ? '[Cross-dealer service · originally sold by ' + ownerAcctName + '] '
                       + (inp.failureDescription == null ? '' : inp.failureDescription)
                    : inp.failureDescription;
                c.Severity = 'Medium';
                c.InitiationDate = Date.today();
                c.Status = 'New';
                c.EstimatedAmount = inp.estimatedAmount;
                c.MileageAtClaim__c = inp.currentMileage;
                c.DiagnosticTroubleCode__c = inp.diagnosticTroubleCode;
                c.FailureDescription__c = inp.failureDescription;
                c.Channel__c = normalizeChannel(inp.channel);

                Integer claimIdx = claimsToInsert.size();
                claimsToInsert.add(c);
                claimIdxToOutputIdx.put(claimIdx, i);
                claimIdxToInput.put(claimIdx, inp);
                claimIdxToVehicle.put(claimIdx, v);
                claimIdxToPart.put(claimIdx, part);

                // Stash cross-dealer info on the Output so the bot/agent can
                // surface "ℹ This vehicle is registered to <other dealer>" to
                // the dealer who is filing the claim through Agentforce.
                out.crossDealer       = isCrossDealer;
                out.originalDealerName = ownerAcctName;
            }

            if (!claimsToInsert.isEmpty()) {
                List<Database.SaveResult> results = Database.insert(claimsToInsert, false);
                Set<Id> successIds = new Set<Id>();

                for (Integer j = 0; j < results.size(); j++) {
                    Integer outIdx = claimIdxToOutputIdx.get(j);
                    Output out = outputs[outIdx];
                    if (results[j].isSuccess()) {
                        out.success = true;
                        out.claimId = claimsToInsert[j].Id;
                        out.status = 'New';
                        successIds.add(claimsToInsert[j].Id);
                    } else {
                        out.success = false;
                        out.message = 'Failed to create claim: '
                            + results[j].getErrors()[0].getMessage();
                    }
                }

                if (!successIds.isEmpty()) {
                    Map<Id, Claim> namedClaims = new Map<Id, Claim>([
                        SELECT Id, Name FROM Claim WHERE Id IN :successIds
                    ]);

                    List<ClaimItem> itemsToInsert = new List<ClaimItem>();

                    for (Integer j = 0; j < results.size(); j++) {
                        if (!results[j].isSuccess()) {
                            continue;
                        }
                        Integer outIdx = claimIdxToOutputIdx.get(j);
                        Output out = outputs[outIdx];
                        Input inp = claimIdxToInput.get(j);
                        Vehicle v = claimIdxToVehicle.get(j);
                        Product2 part = claimIdxToPart.get(j);

                        Claim named = namedClaims.get(claimsToInsert[j].Id);
                        if (named != null) {
                            out.claimNumber = named.Name;
                        }
                        String partName = part != null ? part.Name : 'warranty repair';
                        out.message = 'Warranty claim ' + out.claimNumber
                            + ' created for ' + partName + ' on VIN ' + inp.vinNumber;

                        ClaimItem item = new ClaimItem();
                        item.Name = 'CI-' + out.claimNumber + '-01';
                        item.ClaimId = claimsToInsert[j].Id;
                        item.VehicleId = v.Id;
                        item.Description = inp.failureDescription;
                        item.FaultDate = Date.today();
                        if (part != null) {
                            item.ProductId = part.Id;
                        }
                        item.Type__c = 'Part';
                        item.Status__c = 'Submitted';
                        item.Quantity__c = 1;
                        if (inp.estimatedAmount != null) {
                            item.UnitPrice__c = inp.estimatedAmount;
                        }
                        itemsToInsert.add(item);
                    }

                    if (!itemsToInsert.isEmpty()) {
                        Database.insert(itemsToInsert, false);
                    }

                    // Share every newly-created Claim with the running user
                    // so the dealer who filed via Agentforce can actually SEE
                    // the claim back in their portal. Without this, external
                    // OWD on Claim is Private and the new record is invisible
                    // to the user who created it through the bot.
                    Id runningUserId = UserInfo.getUserId();
                    List<ClaimShare> sharesToInsert = new List<ClaimShare>();
                    for (Id cId : successIds) {
                        sharesToInsert.add(new ClaimShare(
                            ParentId      = cId,
                            UserOrGroupId = runningUserId,
                            AccessLevel   = 'Read',
                            RowCause      = 'Manual'
                        ));
                    }
                    if (!sharesToInsert.isEmpty()) {
                        Database.insert(sharesToInsert, false);
                    }
                }
            }
        } catch (Exception e) {
            outputs.clear();
            for (Input inp : inputs) {
                Output out = new Output();
                out.success = false;
                out.message = 'Error creating warranty claim: ' + e.getMessage();
                outputs.add(out);
            }
        }

        return outputs;
    }

    /**
     * Resolves the SERVICING dealer's Account for the running user. Mirrors
     * WC_DealerServicePortalController.getDealerAccountId() so claim creation
     * via Agentforce attributes claims to the dealer who filed (not the dealer
     * who originally sold the vehicle).
     */
    private static Id resolveRunningDealerAccountId() {
        try {
            List<User> users = [SELECT ContactId, AccountId FROM User
                                WHERE Id = :UserInfo.getUserId() LIMIT 1];
            if (users.isEmpty()) return null;
            if (users[0].AccountId != null) return users[0].AccountId;
            if (users[0].ContactId != null) {
                List<Contact> contacts = [SELECT AccountId FROM Contact
                                          WHERE Id = :users[0].ContactId LIMIT 1];
                if (!contacts.isEmpty() && contacts[0].AccountId != null) return contacts[0].AccountId;
            }
        } catch (Exception e) { /* swallow — fallback chain handles null */ }
        return null;
    }

    private static String normalizeChannel(String raw) {
        if (String.isBlank(raw)) return null;
        String key = raw.trim().toLowerCase().replaceAll('[\\s_-]', '');
        if (key == 'webchat' || key == 'chat' || key == 'web') return 'Web_Chat';
        if (key == 'whatsapp' || key == 'wa') return 'WhatsApp';
        if (key == 'portal' || key == 'experiencecloud' || key == 'community') return 'Portal';
        if (key == 'email' || key == 'mail') return 'Email';
        if (key == 'phone' || key == 'call' || key == 'voice') return 'Phone';
        return raw;
    }

    public class Input {
        @InvocableVariable(required=true label='VIN Number'
            description='17-character VIN of the vehicle for the warranty claim')
        public String vinNumber;

        @InvocableVariable(label='Part Code'
            description='Product code of the spare part (optional)')
        public String partCode;

        @InvocableVariable(label='Failure Description'
            description='Description of the issue or failure as reported by the dealer')
        public String failureDescription;

        @InvocableVariable(label='Current Mileage'
            description='Current odometer reading at time of claim (km)')
        public Decimal currentMileage;

        @InvocableVariable(label='Diagnostic Trouble Code'
            description='OBD-II DTC code if available (e.g. P0300)')
        public String diagnosticTroubleCode;

        @InvocableVariable(label='Dealer Account Id'
            description='Salesforce ID of the dealer Account')
        public String dealerAccountId;

        @InvocableVariable(label='Estimated Amount'
            description='Estimated repair cost')
        public Decimal estimatedAmount;

        @InvocableVariable(label='Channel'
            description='Submission channel. Allowed values: Web_Chat, WhatsApp, Portal, Email, Phone. Common synonyms (WebChat, Chat, Web) are auto-normalized.')
        public String channel;
    }

    public class Output {
        @InvocableVariable(label='Success' description='True if the claim was created successfully')
        public Boolean success;

        @InvocableVariable(label='Claim Id' description='Salesforce record ID of the created Claim')
        public String claimId;

        @InvocableVariable(label='Claim Number' description='Auto-generated claim number')
        public String claimNumber;

        @InvocableVariable(label='Status' description='Initial status of the claim')
        public String status;

        @InvocableVariable(label='Message' description='Confirmation message or error details')
        public String message;

        @InvocableVariable(label='Cross Dealer'
            description='True if the vehicle is registered to a dealer different from the dealer filing this claim. The agent should mention this to the user.')
        public Boolean crossDealer;

        @InvocableVariable(label='Original Dealer Name'
            description='Name of the dealer the vehicle is originally registered to. Populated whenever cross-dealer service is detected.')
        public String originalDealerName;
    }
}