/**
 * WC_DealerServicePortalController
 * Apex controller for wcDealerServicePortal LWC (P15).
 *
 * Vehicle resolution chain (verified against org 2026-04-18):
 *   Vehicle.AssetId → Asset.Id → Asset.AccountId (dealer)
 *   Claim.InsuredAssetId → null in this org (IPA table empty, AssetId field doesn't exist)
 *   Therefore: vehicles displayed from dealer's Asset pool; claim-to-vehicle link not available.
 *
 * Security: S1 IDOR, S3 with sharing + AccountId scope, S5 MIME+magic,
 *           S6, S8 generic errors, S11 attach cap, S13 logging.
 */
public with sharing class WC_DealerServicePortalController {

    private static final Decimal GST_RATE = 0.18;
    private static final Integer MAX_ATTACHMENTS = 10;
    private static final Integer VIN_TX_LIMIT    = 50;
    private static final Set<String> ALLOWED_MIME = new Set<String>{
        'application/pdf','image/jpeg','image/png','image/heic'
    };
    private static Integer vinCallsThisTx = 0;

    // [S7] Test hook — allows tests to inject dealer account without community user
    @TestVisible private static Id testDealerAccountId = null;

    // ─── Helpers ────────────────────────────────────────────────────────

    private static Id getDealerAccountId() {
        if (Test.isRunningTest() && testDealerAccountId != null) return testDealerAccountId;
        List<User> users = [SELECT ContactId, AccountId FROM User
                            WHERE Id = :UserInfo.getUserId() LIMIT 1];
        if (users.isEmpty()) return null;
        if (users[0].AccountId != null) return users[0].AccountId;
        if (users[0].ContactId != null) {
            List<Contact> contacts = [SELECT AccountId FROM Contact
                                      WHERE Id = :users[0].ContactId LIMIT 1];
            if (!contacts.isEmpty() && contacts[0].AccountId != null) return contacts[0].AccountId;
        }
        return null;
    }

    private static AuraHandledException safe(Exception e) {
        String ref = String.valueOf(System.currentTimeMillis()).right(8)
                   + String.valueOf(Math.abs(Crypto.getRandomLong())).right(6);
        System.debug(LoggingLevel.ERROR, 'WC_P15 ref=' + ref + ' type=' + e.getTypeName());
        System.debug(LoggingLevel.FINE,  'WC_P15 ref=' + ref + ' msg='  + e.getMessage()
                                        + ' stack=' + e.getStackTraceString());
        return new AuraHandledException('Unable to complete request. Reference: ' + ref);
    }

    private static Boolean hasValidMagicBytes(Blob raw, String mime) {
        if (raw == null || raw.size() < 4) return false;
        String hex = EncodingUtil.convertToHex(raw)
                     .substring(0, Math.min(16, raw.size() * 2)).toUpperCase();
        if (mime == 'application/pdf') return hex.startsWith('25504446');
        if (mime == 'image/jpeg')      return hex.startsWith('FFD8FF');
        if (mime == 'image/png')       return hex.startsWith('89504E47');
        if (mime == 'image/heic')      return hex.length() >= 16 && hex.substring(8,16).startsWith('66747970');
        return false;
    }

    private static Map<String, Decimal> computeGst(Decimal parts, Decimal labour) {
        Decimal p = parts  == null ? 0 : parts;
        Decimal l = labour == null ? 0 : labour;
        Decimal sub  = p + l;
        Decimal gst  = (sub * GST_RATE).setScale(2, System.RoundingMode.HALF_UP);
        Decimal total = (sub + gst).setScale(2, System.RoundingMode.HALF_UP);
        return new Map<String, Decimal>{
            'partsSubtotal' => p, 'labourSubtotal' => l,
            'subtotal' => sub, 'gst' => gst, 'total' => total
        };
    }

    private static String statusCssClass(String status) {
        if (status == 'Requested Information') return 'sb-action';
        if (status == 'Under Review')          return 'sb-review';
        if (status == 'Approved')              return 'sb-approved';
        if (status == 'Denied' || status == 'Rejected') return 'sb-denied';
        if (status == 'Submitted')             return 'sb-submitted';
        if (status == 'Settled' || status == 'Closed') return 'sb-closed';
        return 'sb-new';
    }

    /** [v22 — Option B 6-stage pipeline]
     *  Stage 1 Filed     ← Draft
     *  Stage 2 Submitted ← New, Submitted
     *  Stage 3 Review    ← Under Review, Requested Information
     *  Stage 4 Decided   ← Approved | Denied | Rejected (LWC shows dynamic label
     *                       + green/red color per claim's actual status)
     *  Stage 5 Settled   ← Settled (only on the approved path; LWC marks N/A
     *                       for denied claims)
     *  Stage 6 Closed    ← Closed
     */
    private static Integer pipelineStage(String status) {
        if (status == 'Draft')                return 1;
        if (status == 'New' || status == 'Submitted') return 2;
        if (status == 'Under Review' || status == 'Requested Information') return 3;
        if (status == 'Approved' || status == 'Denied' || status == 'Rejected') return 4;
        if (status == 'Settled')              return 5;
        return 6; // Closed (and any other terminal state)
    }

    private static String monthLabel(Integer m) {
        List<String> months = new List<String>{
            null,'Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'
        };
        return (m >= 1 && m <= 12) ? months[m] : '';
    }

    // ─── Read Methods ────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDealerPortalData() {
        try {
            Id dealerAccId = getDealerAccountId();

            Map<String, Object> profile = new Map<String, Object>{
                'name' => 'Dealer Portal', 'gstin' => null, 'city' => null,
                'userFullName' => UserInfo.getName(),
                'userEmail'    => UserInfo.getUserEmail(),
                'userId'       => UserInfo.getUserId()
            };
            if (dealerAccId != null) {
                List<Account> accts = [
                    SELECT Name, Dealer_GSTIN__c,
                           BillingStreet, BillingCity, BillingState,
                           BillingPostalCode, BillingCountry, Phone
                    FROM Account WHERE Id = :dealerAccId LIMIT 1
                ];
                if (!accts.isEmpty()) {
                    profile.put('name',          accts[0].Name);
                    profile.put('gstin',         accts[0].Dealer_GSTIN__c);
                    profile.put('street',        accts[0].BillingStreet);
                    profile.put('city',          accts[0].BillingCity);
                    profile.put('state',         accts[0].BillingState);
                    profile.put('postalCode',    accts[0].BillingPostalCode);
                    profile.put('country',       accts[0].BillingCountry);
                    profile.put('phone',         accts[0].Phone);
                    profile.put('accountId',     accts[0].Id);
                }
            }

            List<Claim> rawClaims = new List<Claim>();
            if (dealerAccId != null) {
                // [v23.14] All dealer users at the same Account share the same
                // pool of claims — Vikram (Mumbai) sees every Mumbai claim, not
                // just the ones he personally filed. Read is delegated to a
                // `without sharing` helper that hard-filters by dealerAccId, so
                // the SOQL itself enforces the tenant boundary regardless of
                // per-record ClaimShare rows.
                rawClaims = new DealerScopedClaimReader().listForPortal(dealerAccId);
            }

            // Build VIN → vehicle metadata map (model + year) by joining through Asset → Vehicle
            // for the dealer's fleet. Allows decorating each claim wrapper with vehicle info.
            Map<String, Map<String, Object>> vehicleByVin = new Map<String, Map<String, Object>>();
            if (dealerAccId != null) {
                Set<Id> dealerAssetIds = new Set<Id>();
                for (Asset a : [SELECT Id FROM Asset WHERE AccountId = :dealerAccId]) {
                    dealerAssetIds.add(a.Id);
                }
                if (!dealerAssetIds.isEmpty()) {
                    for (Vehicle v : [
                        SELECT VehicleIdentificationNumber, ModelName, ModelYear, MakeName
                        FROM Vehicle WHERE AssetId IN :dealerAssetIds
                    ]) {
                        if (v.VehicleIdentificationNumber == null) continue;
                        vehicleByVin.put(v.VehicleIdentificationNumber.toUpperCase(),
                            new Map<String, Object>{
                                'model' => v.ModelName,
                                'year'  => v.ModelYear,
                                'make'  => v.MakeName
                            });
                    }
                }
            }

            Map<String, Integer> statusDist = new Map<String, Integer>();
            Decimal approvedTotal = 0;
            Integer approvedCount = 0;
            Integer actionRequired = 0;
            Integer openCount = 0;
            Integer underReviewCount = 0;
            List<DealerClaimWrapper> claims = new List<DealerClaimWrapper>();
            Date today = Date.today();

            for (Claim c : rawClaims) {
                statusDist.put(c.Status, (statusDist.containsKey(c.Status)
                    ? statusDist.get(c.Status) : 0) + 1);

                if (c.Status == 'Requested Information') actionRequired++;
                if (new Set<String>{'New','Draft','Submitted'}.contains(c.Status)) openCount++;
                if (c.Status == 'Under Review') underReviewCount++;
                if (c.Status == 'Approved' && c.ApprovalDate__c != null
                    && c.ApprovalDate__c.dateGmt().year() == today.year()) {
                    approvedTotal += (c.EstimatedAmount != null ? c.EstimatedAmount : 0);
                    approvedCount++;
                }

                Map<String, Decimal> gst = computeGst(c.PartsEstimate__c, c.LaborEstimate__c);
                DealerClaimWrapper w = new DealerClaimWrapper();
                w.id             = c.Id;
                w.name           = c.Name;
                w.status         = c.Status;
                w.severity       = c.Severity;
                w.summary        = c.Summary;
                w.category       = c.ClaimReason;
                w.partsSubtotal  = gst.get('partsSubtotal');
                w.labourSubtotal = gst.get('labourSubtotal');
                w.subtotal       = gst.get('subtotal');
                w.gstAmount      = gst.get('gst');
                w.totalAmount    = c.EstimatedAmount != null ? c.EstimatedAmount : gst.get('total');
                w.initiationDate = c.InitiationDate != null ? c.InitiationDate.dateGmt() : null;
                w.daysSinceFiled = c.InitiationDate != null ? c.InitiationDate.dateGmt().daysBetween(today) : null;
                w.riskScore      = c.Risk_Score__c != null ? c.Risk_Score__c.intValue() : null;
                w.aiRecommendation = c.AI_Recommendation__c;
                w.dealerCode     = c.DealerCode__c;
                w.statusCss      = statusCssClass(c.Status);
                w.pipelineStage  = pipelineStage(c.Status);
                w.vin            = c.Vehicle_VIN__c;
                // [Live-update diff] surface the latest OEM comment + last-modified
                // so the LWC can detect comment-only changes (status didn't flip).
                w.approverComments = c.Approver_Comments__c;
                w.lastModifiedDate = c.LastModifiedDate;
                if (c.Vehicle_VIN__c != null) {
                    Map<String, Object> meta = vehicleByVin.get(c.Vehicle_VIN__c.toUpperCase());
                    if (meta != null) {
                        w.vehicleModel = (String) meta.get('model');
                        w.vehicleYear  = (Integer) meta.get('year');
                    }
                }
                claims.add(w);
            }

            Integer deniedCount = (statusDist.containsKey('Denied') ? statusDist.get('Denied') : 0)
                                + (statusDist.containsKey('Rejected') ? statusDist.get('Rejected') : 0);
            Decimal approvalRate = (approvedCount + deniedCount) > 0
                ? ((Decimal) approvedCount / (approvedCount + deniedCount) * 100).setScale(0)
                : null;

            return new Map<String, Object>{
                'dealerProfile'      => profile,
                'kpis' => new Map<String, Object>{
                    'actionRequired' => actionRequired, 'openClaims' => openCount,
                    'underReview'    => underReviewCount, 'approvedYTD' => approvedTotal.setScale(0),
                    'approvedCount'  => approvedCount, 'approvalRate' => approvalRate,
                    'totalClaims'    => rawClaims.size()
                },
                'claims'             => claims,
                'statusDistribution' => statusDist
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    @AuraEnabled(cacheable=true)
    public static List<VehicleWrapper> getDealerVehicles() {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) return new List<VehicleWrapper>();

            // Assets owned by dealer
            Set<Id> assetIds = new Set<Id>();
            for (Asset a : [SELECT Id FROM Asset WHERE AccountId = :dealerAccId
                           ]) {
                assetIds.add(a.Id);
            }
            if (assetIds.isEmpty()) return new List<VehicleWrapper>();

            // Vehicles by AssetId
            Map<Id, Vehicle> vehicleByAsset = new Map<Id, Vehicle>();
            for (Vehicle v : [
                SELECT AssetId, VehicleIdentificationNumber, MakeName, ModelName,
                       ModelYear, ExteriorColor, LastOdometerReading, ManufacturerWarrantyEndDate
                FROM Vehicle WHERE AssetId IN :assetIds
            ]) {
                vehicleByAsset.put(v.AssetId, v);
            }

            Date today = Date.today();
            Date thirtyDays = today.addDays(30);
            Map<Id, AssetWarranty> warrantyByAsset = new Map<Id, AssetWarranty>();
            for (AssetWarranty aw : [
                SELECT AssetId, StartDate, EndDate, WarrantyType
                FROM AssetWarranty WHERE AssetId IN :assetIds AND EndDate >= :today
                ORDER BY EndDate ASC
            ]) {
                if (!warrantyByAsset.containsKey(aw.AssetId)) warrantyByAsset.put(aw.AssetId, aw);
            }

            List<VehicleWrapper> result = new List<VehicleWrapper>();
            for (Id assetId : assetIds) {
                Vehicle v = vehicleByAsset.get(assetId);
                if (v == null) continue;
                AssetWarranty aw = warrantyByAsset.get(assetId);
                VehicleWrapper w = buildVehicleWrapper(v, assetId, aw, today, thirtyDays);
                result.add(w);
            }
            return result;
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    private static VehicleWrapper buildVehicleWrapper(Vehicle v, Id assetId, AssetWarranty aw, Date today, Date thirtyDays) {
        VehicleWrapper w = new VehicleWrapper();
        w.assetId  = assetId;
        w.vin      = v.VehicleIdentificationNumber;
        w.make     = v.MakeName;
        w.model    = v.ModelName;
        w.year     = v.ModelYear != null ? Integer.valueOf(String.valueOf(v.ModelYear)) : null;
        w.color    = v.ExteriorColor;
        w.odometer = v.LastOdometerReading != null
                   ? Integer.valueOf(v.LastOdometerReading.setScale(0)) : null;
        if (aw == null) {
            w.warrantyStatus = 'Expired'; w.statusCss = 'ws-expired';
        } else if (aw.EndDate <= thirtyDays) {
            w.warrantyStatus = 'Expiring Soon'; w.statusCss = 'ws-expiring';
            w.warrantyEndDate = aw.EndDate; w.daysToExpiry = today.daysBetween(aw.EndDate);
        } else {
            w.warrantyStatus = 'Active'; w.statusCss = 'ws-active'; w.warrantyEndDate = aw.EndDate;
        }
        w.mileagePct = w.odometer != null ? Math.min(100, Integer.valueOf(w.odometer / 80000 * 100)) : 0;
        return w;
    }

    /**
     * [v23.21] cacheable=false on purpose. The drawer detail is the live
     * conversation surface — when an OEM posts a new message or flips
     * status, the dealer expects to see it the next time they click on
     * the notification (or row) without a full page refresh.
     *
     * Under cacheable=true, Lightning Data Service returns the prior
     * result for the same claimId param from cache and never hits the
     * server again — so OEM updates remained invisible until F5.
     *
     * The method is only ever called imperatively here (no @wire), so
     * dropping cacheable has no other consequence.
     */
    @AuraEnabled
    public static DealerClaimDetailWrapper getClaimDetail(Id claimId) {
        try {
            if (claimId == null) throw new AuraHandledException('Claim ID is required.');
            Id dealerAccId = getDealerAccountId();
            // [v23.14] Read via `without sharing` helper so any user at the
            // dealer can pull the detail; the IDOR check below enforces
            // tenant isolation by AccountId.
            List<Claim> rows = new DealerScopedClaimReader().readByIdForDetail(claimId);
            // [S1] IDOR check
            if (rows.isEmpty() || (dealerAccId != null && rows[0].AccountId != dealerAccId)) {
                String ref = String.valueOf(System.currentTimeMillis()).right(8);
                System.debug(LoggingLevel.WARN, 'WC_P15 IDOR ref=' + ref + ' userId=' + UserInfo.getUserId());
                throw new AuraHandledException('Access denied. Reference: ' + ref);
            }
            Claim c = rows[0];
            DealerClaimDetailWrapper w = new DealerClaimDetailWrapper();
            w.id             = c.Id;
            w.name           = c.Name;
            w.status         = c.Status;
            w.severity       = c.Severity;
            w.summary        = c.Summary;
            w.category       = c.ClaimReason;
            w.initiationDate = c.InitiationDate  != null ? c.InitiationDate.dateGmt()  : null;
            w.approvalDate   = c.ApprovalDate__c != null ? c.ApprovalDate__c.dateGmt() : null;
            w.finalizedDate  = c.FinalizedDate   != null ? c.FinalizedDate.dateGmt()   : null;
            w.createdDate    = c.CreatedDate;
            w.riskScore      = c.Risk_Score__c != null ? c.Risk_Score__c.intValue() : null;
            w.aiRecommendation = c.AI_Recommendation__c;
            w.approverComments = c.Approver_Comments__c;
            w.rejectionReason  = c.RejectionReason__c;
            w.dealerResponse   = c.Dealer_Response__c;
            // [v22.4] Decision attribution — surfaces "Atlas AI Triage" for
            // auto-decided claims, or the real user's name for manual decisions.
            w.decidedByName       = WC_ClaimAttribution.decidedByDisplay(c);
            w.decidedByAutoTriage = WC_ClaimAttribution.isAutoTriage(c);
            // [Issue 2] Parse the conversation log into chronological entries
            // for the drawer's Notes tab thread view.
            w.conversation     = ClaimConversationService.parseEntries(c.Conversation_Log__c);
            w.dealerCode       = c.DealerCode__c;
            w.repairOrderNumber = c.RepairOrderNumber__c;
            w.daysSinceFiled   = c.InitiationDate != null ? c.InitiationDate.dateGmt().daysBetween(Date.today()) : null;
            w.failureDescription = c.FailureDescription__c;
            w.correctionDescription = c.CorrectionDescription__c;
            w.diagnosticCode = c.DiagnosticTroubleCode__c;
            w.mileageAtClaim = c.MileageAtClaim__c != null ? c.MileageAtClaim__c.intValue() : null;
            w.pipelineStage  = pipelineStage(c.Status);
            w.statusCss      = statusCssClass(c.Status);
            Map<String, Decimal> gst = computeGst(c.PartsEstimate__c, c.LaborEstimate__c);
            w.partsSubtotal  = gst.get('partsSubtotal');
            w.labourSubtotal = gst.get('labourSubtotal');
            w.subtotal       = gst.get('subtotal');
            w.gstAmount      = gst.get('gst');
            w.totalAmount    = c.EstimatedAmount != null ? c.EstimatedAmount : gst.get('total');
            w.vin            = c.Vehicle_VIN__c;
            // Resolve vehicle make/model/year from the VIN if available in dealer's fleet
            if (c.Vehicle_VIN__c != null && dealerAccId != null) {
                Set<Id> dealerAssetIds = new Set<Id>();
                for (Asset a : [SELECT Id FROM Asset WHERE AccountId = :dealerAccId]) {
                    dealerAssetIds.add(a.Id);
                }
                if (!dealerAssetIds.isEmpty()) {
                    List<Vehicle> vehicleHits = [
                        SELECT MakeName, ModelName, ModelYear
                        FROM Vehicle
                        WHERE AssetId IN :dealerAssetIds
                          AND VehicleIdentificationNumber = :c.Vehicle_VIN__c
                        LIMIT 1
                    ];
                    if (!vehicleHits.isEmpty()) {
                        w.vehicleModel = vehicleHits[0].ModelName;
                        w.vehicleYear  = vehicleHits[0].ModelYear != null
                                       ? Integer.valueOf(String.valueOf(vehicleHits[0].ModelYear)) : null;
                    }
                }
            }
            // [v23.16] Documents — read via `without sharing` helper.
            // ContentDocumentLink has its own row-level visibility for
            // Customer Community Plus users that's separate from the
            // linked-entity sharing. Even when the OEM creates the CDL
            // with Visibility='AllUsers', dealers can't see it under
            // `with sharing` unless they're explicitly shared to the
            // file. Tenant safety preserved by the LinkedEntityId filter
            // (the claim was already access-checked above).
            w.documents = new List<DocumentInfo>();
            for (ContentDocumentLink cdl : new DealerScopedClaimReader().listDocumentsForClaim(c.Id)) {
                DocumentInfo d = new DocumentInfo();
                d.contentDocumentId = cdl.ContentDocumentId;
                d.title     = cdl.ContentDocument.Title;
                d.fileType  = cdl.ContentDocument.FileType;
                d.sizeKb    = cdl.ContentDocument.ContentSize != null
                            ? (cdl.ContentDocument.ContentSize / 1024) : 0;
                d.uploadedAt  = cdl.ContentDocument.CreatedDate;
                d.uploadedBy  = cdl.ContentDocument.CreatedBy.Name;
                // [v23] Icon by file type + downloadable URL for the Messages-tab files grid
                String ft = (cdl.ContentDocument.FileType != null) ? cdl.ContentDocument.FileType.toUpperCase() : '';
                if (ft == 'PDF')                                          d.icon = '📕';
                else if (ft == 'JPG' || ft == 'JPEG' || ft == 'PNG'
                      || ft == 'HEIC' || ft == 'HEIF' || ft == 'WEBP')   d.icon = '🖼';
                else if (ft == 'DOCX' || ft == 'DOC')                     d.icon = '📄';
                else if (ft == 'XLSX' || ft == 'XLS' || ft == 'CSV')      d.icon = '📊';
                else                                                      d.icon = '📎';
                d.downloadUrl = '/sfc/servlet.shepherd/document/download/' + cdl.ContentDocumentId;
                w.documents.add(d);
            }
            w.activityTimeline = buildTimeline(c, w.documents);
            return w;
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getPerformanceMetrics() {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) return new Map<String, Object>();
            Date sixMonthsAgo = Date.today().addMonths(-6).toStartOfMonth();
            Map<String, Integer> monthCounts = new Map<String, Integer>();
            Map<String, Integer> monthApproved = new Map<String, Integer>();
            // [v23.14] Aggregates run via `without sharing` helper so the
            // chart reflects ALL dealer claims, not just the running user's
            // ClaimShare-visible subset.
            DealerScopedClaimReader reader = new DealerScopedClaimReader();
            for (AggregateResult ar : reader.aggregateMonthlyForMetrics(dealerAccId, sixMonthsAgo)) {
                String key = String.valueOf(ar.get('yr')) + '-' + String.valueOf(ar.get('mo'));
                Integer cnt = Integer.valueOf(ar.get('cnt'));
                monthCounts.put(key, (monthCounts.containsKey(key) ? monthCounts.get(key) : 0) + cnt);
                if ('Approved'.equals(String.valueOf(ar.get('Status')))) {
                    monthApproved.put(key, (monthApproved.containsKey(key) ? monthApproved.get(key) : 0) + cnt);
                }
            }
            List<Map<String, Object>> categories = new List<Map<String, Object>>();
            for (AggregateResult ar : reader.aggregateCategoriesForMetrics(dealerAccId)) {
                categories.add(new Map<String, Object>{
                    'category' => ar.get('cat'), 'count' => Integer.valueOf(ar.get('cnt'))
                });
            }
            List<Map<String, Object>> monthly = new List<Map<String, Object>>();
            Date cursor = sixMonthsAgo;
            for (Integer i = 0; i < 6; i++) {
                String key = String.valueOf(cursor.year()) + '-' + String.valueOf(cursor.month());
                monthly.add(new Map<String, Object>{
                    'label'    => monthLabel(cursor.month()),
                    'count'    => monthCounts.containsKey(key)   ? monthCounts.get(key)   : 0,
                    'approved' => monthApproved.containsKey(key) ? monthApproved.get(key) : 0
                });
                cursor = cursor.addMonths(1);
            }
            return new Map<String, Object>{ 'monthly' => monthly, 'categories' => categories };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    /**
     * [v23.6] Rich analytics payload for the Reports tab v2 layout.
     *
     * Returns ONE map with KPIs, cash-flow pipeline, monthly volume w/ outcome
     * split, reimbursement trend, top vehicles, category mix (count + ₹),
     * turnaround histogram, aging queue, claim quality, service-plan
     * opportunities, heat calendar, denial breakdown, labour-vs-parts split,
     * and 3 plain-language insights — all derivable from existing Claim,
     * Asset, Vehicle, AssetWarranty fields. No schema changes.
     *
     * Tenant-scoped via dealerAccountId in every SOQL. Risk_Score__c and
     * AI_Recommendation__c are deliberately excluded from aggregates so the
     * dealer can't reverse-engineer fraud-detection thresholds.
     *
     * periodKey: 'MONTH' | '3M' | '6M' | 'FY' | 'CUSTOM'
     * customFromIso/customToIso: ISO yyyy-MM-dd, only honored when CUSTOM
     * lastSeenIso: client's last-visit timestamp (for the "since you last
     *   visited" digest); null on first call
     */
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDealerAnalytics(String periodKey,
                                                          String customFromIso,
                                                          String customToIso,
                                                          String lastSeenIso) {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) return new Map<String, Object>{ 'empty' => true };

            Date today = Date.today();

            // ── 1. Resolve period window (current + previous for delta calc) ──
            Date dateFrom; Date dateTo = today;
            String periodLabel;
            if (periodKey == null) periodKey = 'WEEK';
            if (periodKey == 'TODAY') { dateFrom = today; periodLabel = 'Today'; }
            else if (periodKey == 'WEEK') { dateFrom = today.toStartOfWeek(); periodLabel = 'This week'; }
            else if (periodKey == 'MONTH') { dateFrom = today.toStartOfMonth(); periodLabel = 'This month'; }
            else if (periodKey == '3M') { dateFrom = today.addMonths(-3); periodLabel = 'Last 3 months'; }
            else if (periodKey == '6M') { dateFrom = today.addMonths(-6); periodLabel = 'Last 6 months'; }
            else if (periodKey == 'FY') {
                Integer fyStartYear = (today.month() >= 4) ? today.year() : today.year() - 1;
                dateFrom = Date.newInstance(fyStartYear, 4, 1);
                periodLabel = 'FY ' + (fyStartYear + 1);
            } else if (periodKey == 'CUSTOM' && String.isNotBlank(customFromIso)) {
                dateFrom = Date.valueOf(customFromIso);
                if (String.isNotBlank(customToIso)) dateTo = Date.valueOf(customToIso);
                periodLabel = 'Custom';
            } else {
                dateFrom = today.toStartOfWeek();
                periodLabel = 'This week';
            }
            // Previous period of equal length, ending the day before current period starts
            Integer periodDays = dateFrom.daysBetween(dateTo);
            Date prevTo   = dateFrom.addDays(-1);
            Date prevFrom = prevTo.addDays(-periodDays);

            // ── 2. Fetch dealer's claims (single query, capped) ──
            // We pull a wide window (max(prevFrom, today−13months)) so trend
            // charts can show 6 months and "previous period" can be computed.
            // [v23.14] Read via without-sharing helper so analytics covers
            // ALL dealer claims (not just running user's own ClaimShare set).
            Date queryFloor = prevFrom < today.addMonths(-13) ? today.addMonths(-13) : prevFrom;
            List<Claim> rawClaims = new DealerScopedClaimReader().listForAnalytics(dealerAccId, queryFloor);

            // ── 3. Fetch dealer fleet (assets + vehicles + warranties) ──
            // Used by service-plan opportunity panel + coverage-at-risk KPI.
            Set<Id> dealerAssetIds = new Set<Id>();
            for (Asset a : [SELECT Id FROM Asset WHERE AccountId = :dealerAccId]) {
                dealerAssetIds.add(a.Id);
            }
            Map<String, Map<String, Object>> vinMeta = new Map<String, Map<String, Object>>();
            Map<Id, Map<String, Object>> assetIdToMeta = new Map<Id, Map<String, Object>>();
            if (!dealerAssetIds.isEmpty()) {
                for (Vehicle v : [
                    SELECT VehicleIdentificationNumber, ModelName, ModelYear, MakeName,
                           AssetId
                    FROM Vehicle WHERE AssetId IN :dealerAssetIds
                ]) {
                    if (v.VehicleIdentificationNumber == null) continue;
                    Map<String, Object> m = new Map<String, Object>{
                        'model' => v.ModelName,
                        'year'  => v.ModelYear,
                        'make'  => v.MakeName,
                        'assetId' => v.AssetId
                    };
                    vinMeta.put(v.VehicleIdentificationNumber.toUpperCase(), m);
                    assetIdToMeta.put(v.AssetId, m);
                }
            }
            // Active warranties by AssetId, with EndDate for coverage-at-risk
            Map<Id, AssetWarranty> warrByAsset = new Map<Id, AssetWarranty>();
            if (!dealerAssetIds.isEmpty()) {
                for (AssetWarranty aw : [
                    SELECT AssetId, EndDate, StartDate
                    FROM AssetWarranty
                    WHERE AssetId IN :dealerAssetIds
                      AND StartDate <= :today
                    ORDER BY EndDate DESC
                ]) {
                    if (!warrByAsset.containsKey(aw.AssetId)) warrByAsset.put(aw.AssetId, aw);
                }
            }

            // ── 4. Bucket claims by period (current vs previous, plus all) ──
            List<Claim> currentClaims  = new List<Claim>();
            List<Claim> previousClaims = new List<Claim>();
            for (Claim c : rawClaims) {
                if (c.InitiationDate == null) continue;
                Date d = c.InitiationDate.dateGmt();
                if (d >= dateFrom && d <= dateTo)        currentClaims.add(c);
                else if (d >= prevFrom && d <= prevTo)   previousClaims.add(c);
            }

            // ── 5. KPI tile values ──
            Decimal curApprovedAmt = 0; Integer curApprovedCnt = 0;
            Decimal prevApprovedAmt = 0; Integer prevApprovedCnt = 0;
            Integer curDenied = 0, prevDenied = 0;
            Integer curUnderReview = 0, curSubmitted = 0, curRequestedInfo = 0;
            Decimal curSubmittedAmt = 0, curUnderReviewAmt = 0, curSettledAmt = 0;
            Integer curSettledCnt = 0, curUnderReviewCnt = 0, curSubmittedCnt = 0;
            List<Decimal> curDecisionDays  = new List<Decimal>();
            List<Decimal> prevDecisionDays = new List<Decimal>();

            for (Claim c : currentClaims) {
                Decimal amt = c.EstimatedAmount != null ? c.EstimatedAmount : 0;
                if (c.Status == 'Approved') {
                    curApprovedAmt += amt; curApprovedCnt++;
                    if (c.ApprovalDate__c != null && c.InitiationDate != null) {
                        curDecisionDays.add(Decimal.valueOf(
                            c.InitiationDate.dateGmt().daysBetween(c.ApprovalDate__c.dateGmt())));
                    }
                }
                if (c.Status == 'Denied' || c.Status == 'Rejected') curDenied++;
                if (c.Status == 'Under Review') { curUnderReview++; curUnderReviewCnt++; curUnderReviewAmt += amt; }
                if (c.Status == 'New' || c.Status == 'Submitted') {
                    curSubmitted++; curSubmittedCnt++; curSubmittedAmt += amt;
                }
                if (c.Status == 'Requested Information') curRequestedInfo++;
                if (c.Status == 'Settled' || c.Status == 'Closed') {
                    curSettledCnt++; curSettledAmt += amt;
                }
            }
            for (Claim c : previousClaims) {
                if (c.Status == 'Approved') {
                    prevApprovedAmt += (c.EstimatedAmount != null ? c.EstimatedAmount : 0);
                    prevApprovedCnt++;
                    if (c.ApprovalDate__c != null && c.InitiationDate != null) {
                        prevDecisionDays.add(Decimal.valueOf(
                            c.InitiationDate.dateGmt().daysBetween(c.ApprovalDate__c.dateGmt())));
                    }
                }
                if (c.Status == 'Denied' || c.Status == 'Rejected') prevDenied++;
            }

            Integer curDecided  = curApprovedCnt + curDenied;
            Integer prevDecided = prevApprovedCnt + prevDenied;
            Decimal curApprovalRate  = curDecided  > 0 ? ((Decimal) curApprovedCnt  / curDecided)  * 100 : 0;
            Decimal prevApprovalRate = prevDecided > 0 ? ((Decimal) prevApprovedCnt / prevDecided) * 100 : 0;
            Decimal curDenialRate    = curDecided  > 0 ? ((Decimal) curDenied       / curDecided)  * 100 : 0;
            Decimal prevDenialRate   = prevDecided > 0 ? ((Decimal) prevDenied      / prevDecided) * 100 : 0;
            Decimal curMedianDays  = pctile(curDecisionDays, 50);
            Decimal curP90Days     = pctile(curDecisionDays, 90);
            Decimal prevMedianDays = pctile(prevDecisionDays, 50);
            Decimal prevP90Days    = pctile(prevDecisionDays, 90);
            Integer overSlaCount = 0;
            for (Decimal d : curDecisionDays) { if (d != null && d > 7) overSlaCount++; }

            // Coverage-at-risk: vehicles with warranty end < 60d OR > 80% time used
            Integer coverageAtRisk = 0;
            for (AssetWarranty aw : warrByAsset.values()) {
                if (aw.EndDate == null) continue;
                Integer daysLeft = today.daysBetween(aw.EndDate);
                if (daysLeft >= 0 && daysLeft <= 60) coverageAtRisk++;
            }

            // Awaiting reply: claims with status 'Requested Information' and how many ≥ 4 days old
            Integer awaitingReply = 0; Integer awaitingReplyOverdue = 0;
            for (Claim c : rawClaims) {
                if (c.Status != 'Requested Information') continue;
                awaitingReply++;
                if (c.LastModifiedDate != null) {
                    Integer daysSince = c.LastModifiedDate.dateGmt().daysBetween(today);
                    if (daysSince >= 4) awaitingReplyOverdue++;
                }
            }

            // ── 6. Cash-flow pipeline (across ALL claims, not period-filtered) ──
            // [v23.20] Cash flow is a STATE question — "where is my money
            // right now in the warranty cycle". A period-filtered iterator
            // would miss claims older than the window that are still
            // open / under review. We do a dedicated status aggregate
            // covering the dealer's entire claim history.
            Decimal cfSubmittedAmt = 0, cfReviewAmt = 0, cfApprovedAmt = 0, cfPaidAmt = 0;
            Integer cfSubmittedCnt = 0, cfReviewCnt = 0, cfApprovedCnt = 0, cfPaidCnt = 0;
            for (AggregateResult ar : new DealerScopedClaimReader().aggregateCashflow(dealerAccId)) {
                String st = (String) ar.get('status');
                Integer n = (Integer) ar.get('cnt');
                Decimal amt = (Decimal) ar.get('amt');
                if (amt == null) amt = 0;
                if (st == 'New' || st == 'Submitted' || st == 'Requested Information') {
                    cfSubmittedAmt += amt; cfSubmittedCnt += n;
                } else if (st == 'Under Review') {
                    cfReviewAmt    += amt; cfReviewCnt    += n;
                } else if (st == 'Approved') {
                    cfApprovedAmt  += amt; cfApprovedCnt  += n;
                } else if (st == 'Settled' || st == 'Closed') {
                    cfPaidAmt      += amt; cfPaidCnt      += n;
                }
            }

            // ── 7. Monthly volume + reimbursement trend (last 6 months) ──
            Date trendFrom = today.addMonths(-5).toStartOfMonth();
            Map<String, Map<String, Decimal>> monthAgg = new Map<String, Map<String, Decimal>>();
            for (Claim c : rawClaims) {
                if (c.InitiationDate == null) continue;
                Date d = c.InitiationDate.dateGmt();
                if (d < trendFrom) continue;
                String key = String.valueOf(d.year()) + '-' + String.valueOf(d.month()).leftPad(2, '0');
                if (!monthAgg.containsKey(key)) monthAgg.put(key,
                    new Map<String, Decimal>{ 'total' => 0, 'approved' => 0, 'denied' => 0, 'pending' => 0, 'amount' => 0 });
                Map<String, Decimal> m = monthAgg.get(key);
                m.put('total', m.get('total') + 1);
                Decimal amt = c.EstimatedAmount != null ? c.EstimatedAmount : 0;
                if (c.Status == 'Approved') {
                    m.put('approved', m.get('approved') + 1);
                    m.put('amount', m.get('amount') + amt);
                } else if (c.Status == 'Denied' || c.Status == 'Rejected') {
                    m.put('denied', m.get('denied') + 1);
                } else {
                    m.put('pending', m.get('pending') + 1);
                }
            }
            List<Map<String, Object>> monthlyOut = new List<Map<String, Object>>();
            List<Map<String, Object>> trendOut   = new List<Map<String, Object>>();
            Date cursor = trendFrom;
            for (Integer i = 0; i < 6; i++) {
                String key = String.valueOf(cursor.year()) + '-' + String.valueOf(cursor.month()).leftPad(2, '0');
                Map<String, Decimal> m = monthAgg.containsKey(key) ? monthAgg.get(key)
                    : new Map<String, Decimal>{ 'total' => 0, 'approved' => 0, 'denied' => 0, 'pending' => 0, 'amount' => 0 };
                String label = monthLabel(cursor.month());
                monthlyOut.add(new Map<String, Object>{
                    'label' => label, 'total' => m.get('total').intValue(),
                    'approved' => m.get('approved').intValue(),
                    'denied'   => m.get('denied').intValue(),
                    'pending'  => m.get('pending').intValue()
                });
                trendOut.add(new Map<String, Object>{
                    'label' => label, 'amount' => m.get('amount').setScale(0),
                    'isForecast' => false
                });
                cursor = cursor.addMonths(1);
            }

            // ── 8. Top 5 vehicles by claim count (period) ──
            Map<String, Map<String, Object>> vinAgg = new Map<String, Map<String, Object>>();
            for (Claim c : currentClaims) {
                if (c.Vehicle_VIN__c == null) continue;
                String vin = c.Vehicle_VIN__c.toUpperCase();
                if (!vinAgg.containsKey(vin)) {
                    Map<String, Object> meta = vinMeta.get(vin);
                    String label = (meta != null && meta.get('year') != null && meta.get('model') != null)
                        ? String.valueOf(meta.get('year')) + ' ' + String.valueOf(meta.get('model'))
                        : 'Unknown';
                    vinAgg.put(vin, new Map<String, Object>{
                        'vin' => vin, 'label' => label, 'count' => 0,
                        'amount' => 0, 'inReview' => false, 'denied' => 0
                    });
                }
                Map<String, Object> v = vinAgg.get(vin);
                v.put('count', ((Integer) v.get('count')) + 1);
                if (c.Status == 'Approved') {
                    v.put('amount', ((Decimal) v.get('amount')) + (c.EstimatedAmount != null ? c.EstimatedAmount : 0));
                }
                if (c.Status == 'Under Review' || c.Status == 'Submitted'
                    || c.Status == 'Requested Information') {
                    v.put('inReview', true);
                }
                if (c.Status == 'Denied' || c.Status == 'Rejected') {
                    v.put('denied', ((Integer) v.get('denied')) + 1);
                }
            }
            List<Map<String, Object>> topVehicles = vinAgg.values();
            topVehicles.sort(new VinClaimComparator());
            if (topVehicles.size() > 5) {
                List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
                for (Integer i = 0; i < 5; i++) trimmed.add(topVehicles[i]);
                topVehicles = trimmed;
            }

            // ── 9. Category mix (count + ₹) ──
            Map<String, Map<String, Decimal>> catAgg = new Map<String, Map<String, Decimal>>();
            for (Claim c : currentClaims) {
                String cat = String.isBlank(c.ClaimReason) ? 'Uncategorised' : c.ClaimReason;
                if (!catAgg.containsKey(cat)) catAgg.put(cat,
                    new Map<String, Decimal>{ 'count' => 0, 'amount' => 0 });
                Map<String, Decimal> m = catAgg.get(cat);
                m.put('count', m.get('count') + 1);
                if (c.Status == 'Approved') {
                    m.put('amount', m.get('amount') + (c.EstimatedAmount != null ? c.EstimatedAmount : 0));
                }
            }
            List<Map<String, Object>> catList = new List<Map<String, Object>>();
            for (String k : catAgg.keySet()) {
                Map<String, Decimal> m = catAgg.get(k);
                catList.add(new Map<String, Object>{
                    'category' => k,
                    'count' => m.get('count').intValue(),
                    'amount' => m.get('amount').setScale(0)
                });
            }
            catList.sort(new CatAmountComparator());
            if (catList.size() > 5) {
                List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
                for (Integer i = 0; i < 5; i++) trimmed.add(catList[i]);
                catList = trimmed;
            }

            // ── 10. Turnaround histogram (5 buckets, approved only) ──
            Integer t01 = 0, t23 = 0, t47 = 0, t814 = 0, t15 = 0;
            for (Decimal d : curDecisionDays) {
                if (d == null) continue;
                if (d <= 1)       t01++;
                else if (d <= 3)  t23++;
                else if (d <= 7)  t47++;
                else if (d <= 14) t814++;
                else              t15++;
            }
            List<Map<String, Object>> turnBuckets = new List<Map<String, Object>>{
                new Map<String, Object>{ 'label' => '0–1d',  'count' => t01,  'severity' => 'ok' },
                new Map<String, Object>{ 'label' => '2–3d',  'count' => t23,  'severity' => 'med' },
                new Map<String, Object>{ 'label' => '4–7d',  'count' => t47,  'severity' => 'ok' },
                new Map<String, Object>{ 'label' => '8–14d', 'count' => t814, 'severity' => 'tail' },
                new Map<String, Object>{ 'label' => '15+d',  'count' => t15,  'severity' => 'tail' }
            };

            // ── 11. Aging queue (open claims by age) ──
            Integer age07 = 0, age814 = 0, age1530 = 0, age30 = 0;
            String oldestOpenName = null; Integer oldestOpenDays = 0;
            Integer aging814AwaitingReply = 0;
            for (Claim c : rawClaims) {
                if (c.Status == 'Approved' || c.Status == 'Denied' || c.Status == 'Rejected'
                    || c.Status == 'Settled' || c.Status == 'Closed') continue;
                if (c.InitiationDate == null) continue;
                Integer ageDays = c.InitiationDate.dateGmt().daysBetween(today);
                if (ageDays <= 7) age07++;
                else if (ageDays <= 14) {
                    age814++;
                    if (c.Status == 'Requested Information') aging814AwaitingReply++;
                } else if (ageDays <= 30) age1530++;
                else { age30++;
                    if (oldestOpenDays == 0 || ageDays > oldestOpenDays) {
                        oldestOpenDays = ageDays; oldestOpenName = c.Name;
                    }
                }
            }

            // ── 12. Claim quality (current period) ──
            // First-time-right approximation: Approved AND status never went through
            // 'Requested Information' (we don't have history; approximate: Approved
            // claims = first-time-right; current 'Requested Information' = needsInfo.)
            Integer qFTR = curApprovedCnt;
            Integer qNeedsInfo = curRequestedInfo;
            Integer qDenied = curDenied;
            Integer qPending = curUnderReview + curSubmitted;
            Integer qTotal = qFTR + qNeedsInfo + qDenied + qPending;
            if (qTotal == 0) qTotal = 1; // avoid div by zero

            // ── 13. Service-plan opportunities ──
            // Vehicles with warranty ending < 60 days AND ≥ 1 claim in last 90 days.
            Set<Id> recentClaimAssetIds = new Set<Id>();
            Map<Id, Integer> claimsThisYearByAsset = new Map<Id, Integer>();
            Map<Id, Decimal> approvedThisYearByAsset = new Map<Id, Decimal>();
            Date ninetyDaysAgo = today.addDays(-90);
            Date yearStart = today.addDays(-365);
            for (Claim c : rawClaims) {
                if (c.Vehicle_VIN__c == null || c.InitiationDate == null) continue;
                Map<String, Object> meta = vinMeta.get(c.Vehicle_VIN__c.toUpperCase());
                if (meta == null) continue;
                Id assetId = (Id) meta.get('assetId');
                if (assetId == null) continue;
                Date initD = c.InitiationDate.dateGmt();
                if (initD >= ninetyDaysAgo) recentClaimAssetIds.add(assetId);
                if (initD >= yearStart) {
                    claimsThisYearByAsset.put(assetId,
                        (claimsThisYearByAsset.containsKey(assetId) ? claimsThisYearByAsset.get(assetId) : 0) + 1);
                    if (c.Status == 'Approved') {
                        Decimal amt = c.EstimatedAmount != null ? c.EstimatedAmount : 0;
                        approvedThisYearByAsset.put(assetId,
                            (approvedThisYearByAsset.containsKey(assetId) ? approvedThisYearByAsset.get(assetId) : 0) + amt);
                    }
                }
            }
            List<Map<String, Object>> servicePlanOpps = new List<Map<String, Object>>();
            for (Id assetId : warrByAsset.keySet()) {
                AssetWarranty aw = warrByAsset.get(assetId);
                if (aw.EndDate == null) continue;
                Integer daysLeft = today.daysBetween(aw.EndDate);
                if (daysLeft < 0 || daysLeft > 60) continue;
                if (!recentClaimAssetIds.contains(assetId)) continue;
                Map<String, Object> meta = assetIdToMeta.get(assetId);
                if (meta == null) continue;
                String label = (meta.get('year') != null && meta.get('model') != null)
                    ? String.valueOf(meta.get('year')) + ' ' + String.valueOf(meta.get('model'))
                    : 'Unknown';
                String vinForOpp = null;
                for (String vk : vinMeta.keySet()) {
                    if (((Id) vinMeta.get(vk).get('assetId')) == assetId) { vinForOpp = vk; break; }
                }
                servicePlanOpps.add(new Map<String, Object>{
                    'vin'       => vinForOpp,
                    'label'     => label,
                    'daysLeft'  => daysLeft,
                    'claimsThisYear' => claimsThisYearByAsset.containsKey(assetId)
                                        ? claimsThisYearByAsset.get(assetId) : 0,
                    'approvedAmount' => approvedThisYearByAsset.containsKey(assetId)
                                        ? approvedThisYearByAsset.get(assetId).setScale(0) : 0
                });
            }
            servicePlanOpps.sort(new OppDaysLeftComparator());
            if (servicePlanOpps.size() > 6) {
                List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
                for (Integer i = 0; i < 6; i++) trimmed.add(servicePlanOpps[i]);
                servicePlanOpps = trimmed;
            }

            // ── 14. Heat calendar (12 weeks, by day) ──
            Date heatFrom = today.addDays(-83); // 12 weeks
            Map<Date, Integer> dayCounts = new Map<Date, Integer>();
            Integer maxDayCount = 0;
            for (Claim c : rawClaims) {
                if (c.InitiationDate == null) continue;
                Date d = c.InitiationDate.dateGmt();
                if (d < heatFrom || d > today) continue;
                Integer n = (dayCounts.containsKey(d) ? dayCounts.get(d) : 0) + 1;
                dayCounts.put(d, n);
                if (n > maxDayCount) maxDayCount = n;
            }
            // Bucket per day → intensity 0-4 (for CSS classes data-h="0|1|2|3|4")
            List<Map<String, Object>> heatCells = new List<Map<String, Object>>();
            for (Integer i = 0; i < 84; i++) {
                Date d = heatFrom.addDays(i);
                Integer n = dayCounts.containsKey(d) ? dayCounts.get(d) : 0;
                Integer intensity = 0;
                if (maxDayCount > 0) {
                    Decimal pct = ((Decimal) n / maxDayCount) * 4;
                    intensity = pct.intValue();
                    if (intensity > 4) intensity = 4;
                }
                heatCells.add(new Map<String, Object>{
                    'date' => String.valueOf(d), 'count' => n, 'intensity' => intensity
                });
            }
            // Busiest weekday (1=Mon..7=Sun in this calc; use day of week from Date.toStartOfWeek diff)
            Map<Integer, Integer> dowCounts = new Map<Integer, Integer>();
            for (Date d : dayCounts.keySet()) {
                Date weekStart = d.toStartOfWeek();
                Integer dow = weekStart.daysBetween(d); // 0..6, 0 = start of week
                dowCounts.put(dow, (dowCounts.containsKey(dow) ? dowCounts.get(dow) : 0) + dayCounts.get(d));
            }
            Integer busiestDow = -1; Integer busiestDowCount = -1;
            for (Integer dow : dowCounts.keySet()) {
                if (dowCounts.get(dow) > busiestDowCount) {
                    busiestDow = dow; busiestDowCount = dowCounts.get(dow);
                }
            }
            String[] dowNames = new String[]{ 'Sun','Mon','Tue','Wed','Thu','Fri','Sat' };
            String busiestDowLabel = (busiestDow >= 0 && busiestDow < 7) ? dowNames[busiestDow] + ' busiest' : null;

            // ── 15. Denial breakdown (by category — fallback for "denial reasons") ──
            Map<String, Integer> deniedByCat = new Map<String, Integer>();
            Integer deniedTotal = 0;
            for (Claim c : currentClaims) {
                if (c.Status != 'Denied' && c.Status != 'Rejected') continue;
                String cat = String.isBlank(c.ClaimReason) ? 'Uncategorised' : c.ClaimReason;
                deniedByCat.put(cat, (deniedByCat.containsKey(cat) ? deniedByCat.get(cat) : 0) + 1);
                deniedTotal++;
            }
            List<Map<String, Object>> denialBreakdown = new List<Map<String, Object>>();
            for (String k : deniedByCat.keySet()) {
                Integer n = deniedByCat.get(k);
                denialBreakdown.add(new Map<String, Object>{
                    'category' => k, 'count' => n,
                    'pct' => deniedTotal > 0 ? Math.round(((Decimal) n / deniedTotal) * 100) : 0
                });
            }
            denialBreakdown.sort(new DenialCountComparator());
            if (denialBreakdown.size() > 5) {
                List<Map<String, Object>> trimmed = new List<Map<String, Object>>();
                for (Integer i = 0; i < 5; i++) trimmed.add(denialBreakdown[i]);
                denialBreakdown = trimmed;
            }

            // ── 16. Labour vs parts split (approved only, current period) ──
            Decimal laborSum = 0, partsSum = 0;
            for (Claim c : currentClaims) {
                if (c.Status != 'Approved') continue;
                if (c.LaborEstimate__c != null) laborSum += c.LaborEstimate__c;
                if (c.PartsEstimate__c != null) partsSum += c.PartsEstimate__c;
            }
            Decimal lpTotal = laborSum + partsSum;
            Decimal laborPct = lpTotal > 0 ? Math.round(((Decimal) laborSum / lpTotal) * 100) : 0;
            Decimal partsPct = 100 - laborPct;

            // ── 17. Insights (3 plain-language observations) ──
            List<Map<String, Object>> insights = new List<Map<String, Object>>();
            // (a) Top category MoM change
            if (catList.size() > 0) {
                Map<String, Object> top = catList[0];
                insights.add(new Map<String, Object>{
                    'kind' => 'alert',
                    'title' => String.valueOf(top.get('category')) + ' is your top category.',
                    'body' => String.valueOf(top.get('count')) + ' claims, ₹' +
                              formatInr((Decimal) top.get('amount')) + ' approved this period.'
                });
            }
            // (b) Approval rate trend
            if (curDecided > 0 && prevDecided > 0) {
                Integer delta = (Integer) (curApprovalRate - prevApprovalRate).round();
                if (delta >= 3) {
                    insights.add(new Map<String, Object>{
                        'kind' => 'good',
                        'title' => 'Approval rate climbing.',
                        'body' => prevApprovalRate.intValue() + '% → ' + curApprovalRate.intValue()
                                  + '% over ' + periodLabel.toLowerCase() + '. Documentation quality improving.'
                    });
                } else if (delta <= -3) {
                    insights.add(new Map<String, Object>{
                        'kind' => 'alert',
                        'title' => 'Approval rate dropped.',
                        'body' => prevApprovalRate.intValue() + '% → ' + curApprovalRate.intValue()
                                  + '%. Review denied claims for documentation gaps.'
                    });
                }
            }
            // (c) Coverage at risk
            if (coverageAtRisk > 0) {
                insights.add(new Map<String, Object>{
                    'kind' => 'info',
                    'title' => coverageAtRisk + ' vehicles approaching warranty expiry.',
                    'body' => 'Reach out for service-plan offers — see opportunities panel.'
                });
            }
            // pad with neutral if < 3
            if (insights.size() < 3) {
                insights.add(new Map<String, Object>{
                    'kind' => 'info',
                    'title' => 'Median decision: ' + curMedianDays.setScale(1) + 'd.',
                    'body' => overSlaCount + ' claim(s) over the 7-day SLA window.'
                });
            }

            // ── 18. "Since you last visited" digest ──
            Datetime lastSeen = null;
            if (String.isNotBlank(lastSeenIso)) {
                try { lastSeen = Datetime.valueOfGmt(lastSeenIso.replace('T', ' ').substring(0, 19)); }
                catch (Exception e) { lastSeen = null; }
            }
            Integer dgNewApprovals = 0, dgNewDenials = 0, dgNewInfoReq = 0;
            Decimal dgNewApprovedAmt = 0;
            if (lastSeen != null) {
                for (Claim c : rawClaims) {
                    if (c.LastModifiedDate == null || c.LastModifiedDate < lastSeen) continue;
                    if (c.Status == 'Approved') {
                        dgNewApprovals++;
                        dgNewApprovedAmt += (c.EstimatedAmount != null ? c.EstimatedAmount : 0);
                    } else if (c.Status == 'Denied' || c.Status == 'Rejected') {
                        dgNewDenials++;
                    } else if (c.Status == 'Requested Information') {
                        dgNewInfoReq++;
                    }
                }
            }

            // ── 19. Build result map ──
            return new Map<String, Object>{
                'period' => new Map<String, Object>{
                    'key' => periodKey, 'label' => periodLabel,
                    'dateFrom' => String.valueOf(dateFrom),
                    'dateTo'   => String.valueOf(dateTo),
                    'days' => periodDays
                },
                'kpis' => new Map<String, Object>{
                    'filed'           => deltaTile(currentClaims.size(), previousClaims.size(), 'pct'),
                    'approvalRate'    => deltaTile(curApprovalRate.intValue(), prevApprovalRate.intValue(), 'pts'),
                    'approvedAmount'  => deltaTile(curApprovedAmt.setScale(0), prevApprovedAmt.setScale(0), 'amount'),
                    'medianDecision'  => deltaTileDays(curMedianDays, prevMedianDays),
                    'p90Decision'     => deltaTileDays(curP90Days,    prevP90Days),
                    'awaitingReply'   => new Map<String, Object>{
                        'value' => awaitingReply, 'overdue' => awaitingReplyOverdue
                    },
                    'denialRate'      => deltaTile(curDenialRate.intValue(), prevDenialRate.intValue(), 'pts'),
                    'coverageAtRisk'  => new Map<String, Object>{ 'value' => coverageAtRisk }
                },
                'cashflow' => new Map<String, Object>{
                    'submitted'  => new Map<String, Object>{ 'amount' => cfSubmittedAmt.setScale(0), 'count' => cfSubmittedCnt },
                    'underReview'=> new Map<String, Object>{ 'amount' => cfReviewAmt.setScale(0),    'count' => cfReviewCnt    },
                    'approved'   => new Map<String, Object>{ 'amount' => cfApprovedAmt.setScale(0),  'count' => cfApprovedCnt  },
                    'paid'       => new Map<String, Object>{ 'amount' => cfPaidAmt.setScale(0),      'count' => cfPaidCnt      }
                },
                'monthly' => monthlyOut,
                'reimbursementTrend' => trendOut,
                'topVehicles' => topVehicles,
                'categories'  => catList,
                'turnaround'  => new Map<String, Object>{
                    'buckets' => turnBuckets,
                    'median'  => curMedianDays.setScale(1),
                    'p90'     => curP90Days.setScale(1),
                    'overSla' => overSlaCount
                },
                'aging' => new Map<String, Object>{
                    'b1' => age07, 'b2' => age814, 'b3' => age1530, 'b4' => age30,
                    'b2AwaitingReply' => aging814AwaitingReply,
                    'oldestOpenName'  => oldestOpenName,
                    'oldestOpenDays'  => oldestOpenDays
                },
                'quality' => new Map<String, Object>{
                    'firstTimeRight' => Math.round(((Decimal) qFTR / qTotal) * 100),
                    'needsInfo'      => Math.round(((Decimal) qNeedsInfo / qTotal) * 100),
                    'denied'         => Math.round(((Decimal) qDenied / qTotal) * 100),
                    'pending'        => Math.round(((Decimal) qPending / qTotal) * 100),
                    'total'          => qTotal
                },
                'servicePlanOpps' => servicePlanOpps,
                'heatCalendar' => new Map<String, Object>{
                    'cells' => heatCells, 'busiestDay' => busiestDowLabel,
                    'maxPerDay' => maxDayCount
                },
                'denialBreakdown' => denialBreakdown,
                'laborParts' => new Map<String, Object>{
                    'laborAmount' => laborSum.setScale(0),
                    'partsAmount' => partsSum.setScale(0),
                    'totalAmount' => lpTotal.setScale(0),
                    'laborPct' => laborPct.intValue(),
                    'partsPct' => partsPct.intValue()
                },
                'insights' => insights,
                'digest' => new Map<String, Object>{
                    'hasLastSeen'    => lastSeen != null,
                    'newApprovals'   => dgNewApprovals,
                    'newDenials'     => dgNewDenials,
                    'newInfoReq'     => dgNewInfoReq,
                    'newApprovedAmt' => dgNewApprovedAmt.setScale(0)
                }
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    // ─── Analytics helpers ────────────────────────────────────────────────

    private static Decimal pctile(List<Decimal> xs, Integer p) {
        if (xs == null || xs.isEmpty()) return 0;
        List<Decimal> sorted = new List<Decimal>(xs);
        sorted.sort();
        Integer n = sorted.size();
        Integer idx = (Integer) Math.floor((Decimal) (n - 1) * p / 100);
        if (idx < 0) idx = 0;
        if (idx >= n) idx = n - 1;
        return sorted[idx];
    }

    private static Map<String, Object> deltaTile(Object cur, Object prev, String unit) {
        Decimal c = (cur  instanceof Integer) ? (Decimal) ((Integer) cur)  : (Decimal) cur;
        Decimal p = (prev instanceof Integer) ? (Decimal) ((Integer) prev) : (Decimal) prev;
        String dir = 'flat';
        Decimal delta = 0;
        if (p > 0) {
            delta = c - p;
            if (unit == 'pct') delta = (delta / p * 100).setScale(0);
            else if (unit == 'pts') { /* delta as-is, already in points */ }
            else if (unit == 'amount') { /* delta as currency */ }
            if (delta > 0) dir = 'up';
            else if (delta < 0) dir = 'dn';
        } else if (c > 0) {
            dir = 'up'; delta = c;
        }
        return new Map<String, Object>{
            'value' => c, 'prev' => p, 'delta' => delta, 'direction' => dir, 'unit' => unit
        };
    }

    private static Map<String, Object> deltaTileDays(Decimal cur, Decimal prev) {
        // For days metrics, lower is better — flip the direction semantics
        String dir = 'flat';
        Decimal delta = 0;
        if (prev > 0) {
            delta = (cur - prev).setScale(1);
            if (delta < 0) dir = 'up';   // faster than before = good
            else if (delta > 0) dir = 'dn'; // slower than before = bad
        }
        return new Map<String, Object>{
            'value' => cur.setScale(1), 'prev' => prev.setScale(1),
            'delta' => delta, 'direction' => dir, 'unit' => 'days'
        };
    }

    private static String formatInr(Decimal n) {
        if (n == null) return '0';
        if (n >= 100000) return (n / 100000).setScale(1) + 'L';
        if (n >= 1000)   return (n / 1000).setScale(0) + 'k';
        return String.valueOf(n.intValue());
    }

    public class VinClaimComparator implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Integer ca = (Integer) a.get('count'); Integer cb = (Integer) b.get('count');
            if (cb != ca) return cb - ca;
            Decimal aa = (Decimal) a.get('amount'); Decimal ab = (Decimal) b.get('amount');
            return ab > aa ? 1 : (ab < aa ? -1 : 0);
        }
    }

    public class CatAmountComparator implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Decimal aa = (Decimal) a.get('amount'); Decimal ab = (Decimal) b.get('amount');
            if (ab != aa) return ab > aa ? 1 : -1;
            Integer ca = (Integer) a.get('count'); Integer cb = (Integer) b.get('count');
            return cb - ca;
        }
    }

    public class OppDaysLeftComparator implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            Integer aa = (Integer) a.get('daysLeft'); Integer bb = (Integer) b.get('daysLeft');
            return aa - bb;
        }
    }

    public class DenialCountComparator implements System.Comparator<Map<String, Object>> {
        public Integer compare(Map<String, Object> a, Map<String, Object> b) {
            return ((Integer) b.get('count')) - ((Integer) a.get('count'));
        }
    }

    @AuraEnabled(cacheable=true)
    public static VehicleWrapper lookupVIN(String vin) {
        try {
            vinCallsThisTx++;
            if (vinCallsThisTx > VIN_TX_LIMIT) throw new AuraHandledException('Too many VIN lookups. Refresh the page.');
            if (String.isBlank(vin) || vin.length() < 4) return null;
            String cleanVin = vin.trim().toUpperCase();
            // Cross-dealer VIN lookup MUST bypass sharing. The class is `with
            // sharing`, but Customer Community Plus dealer users (e.g. Vikram
            // at Mumbai Premium Electra) cannot see Vehicle / Asset / Account
            // records owned by OTHER dealers under the default sharing model.
            // Without bypass, pasting a Bangalore VIN as a Mumbai dealer would
            // (incorrectly) return null and the cross-dealer flow would never
            // fire. Cross-dealer warranty service is an explicitly authorized
            // business scenario — any Electra dealer can service any Electra
            // VIN — so the elevated read of vehicle-identifier metadata is
            // safe and intentional. We expose ONLY the fields the LWC needs.
            VehicleProbe p = new CrossDealerLookup().findVehicleByVin(cleanVin);
            if (p == null) return null;

            VehicleWrapper w = buildVehicleWrapper(p.veh, p.veh.AssetId, p.aw,
                                                   Date.today(), Date.today().addDays(30));
            w.ownerDealerAccountId = p.ownerAcctId;
            w.ownerDealerName      = p.ownerAcctName;
            Id currentDealerId     = getDealerAccountId();
            w.crossDealer          = (p.ownerAcctId != null && currentDealerId != null
                                      && p.ownerAcctId != currentDealerId);
            if (p.veh.AssetId != null) {
                w.priorClaimsCount = 0;
            }
            return w;
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    /**
     * Probe struct returned from CrossDealerLookup. Apex disallows inner-inner
     * classes, so VehicleProbe is a peer inner class (not nested inside
     * CrossDealerLookup). Carries only what the LWC needs — no PII, no
     * financial fields cross the sharing boundary.
     */
    public class VehicleProbe {
        public Vehicle veh;
        public AssetWarranty aw;
        public Id ownerAcctId;
        public String ownerAcctName;
    }

    /**
     * [v23.14] Encapsulated `without sharing` helper for dealer-SCOPED Claim
     * reads. Without this, Customer Community Plus dealer users only see
     * Claim records explicitly shared to them via per-record ClaimShare
     * rows — i.e. only claims they personally created. Vikram (Mumbai)
     * could not see claims another Mumbai user filed on the same Account.
     *
     * SAFETY: every method here either:
     *   (a) filters by `AccountId = :dealerAccId` (caller-supplied,
     *       derived from the running user's own AccountId), so the SOQL
     *       cannot leak across dealer boundaries; or
     *   (b) returns by Claim Id and REQUIRES the caller to verify
     *       `claim.AccountId == dealerAccId` before acting on the row.
     * The outer class stays `with sharing`; this helper is the narrow
     * exception used only for queries the dealer's user has a legitimate
     * tenant-scoped right to read regardless of per-record sharing.
     */
    private without sharing class DealerScopedClaimReader {
        /** Main portal claim list — full field set used by getDealerPortalData. */
        public List<Claim> listForPortal(Id dealerAccId) {
            return [
                SELECT Id, Name, Status, Severity, Summary, ClaimReason,
                       EstimatedAmount, PartsEstimate__c, LaborEstimate__c,
                       AccountId, InitiationDate, FinalizedDate,
                       ApprovalDate__c, Risk_Score__c, AI_Recommendation__c,
                       DealerCode__c, Vehicle_VIN__c,
                       Approver_Comments__c, LastModifiedDate
                FROM Claim
                WHERE AccountId = :dealerAccId
                ORDER BY LastModifiedDate DESC
                LIMIT 200
            ];
        }

        /** Wide window for v23.6 analytics (period + previous-period delta). */
        public List<Claim> listForAnalytics(Id dealerAccId, Date floor) {
            return [
                SELECT Id, Name, Status, ClaimReason, EstimatedAmount,
                       PartsEstimate__c, LaborEstimate__c, InitiationDate,
                       FinalizedDate, ApprovalDate__c, Vehicle_VIN__c,
                       Severity, LastModifiedDate
                FROM Claim
                WHERE AccountId = :dealerAccId
                  AND InitiationDate >= :floor
                ORDER BY InitiationDate DESC
                LIMIT 1000
            ];
        }

        /** Monthly volume + status aggregates (last 6 months). */
        public List<AggregateResult> aggregateMonthlyForMetrics(Id dealerAccId, Date sixMonthsAgo) {
            return [
                SELECT CALENDAR_YEAR(InitiationDate) yr, CALENDAR_MONTH(InitiationDate) mo,
                       COUNT(Id) cnt, Status
                FROM Claim
                WHERE AccountId = :dealerAccId AND InitiationDate >= :sixMonthsAgo
                GROUP BY CALENDAR_YEAR(InitiationDate), CALENDAR_MONTH(InitiationDate), Status
            ];
        }

        /** Top categories by claim count (no time bound). */
        public List<AggregateResult> aggregateCategoriesForMetrics(Id dealerAccId) {
            return [
                SELECT ClaimReason cat, COUNT(Id) cnt
                FROM Claim
                WHERE AccountId = :dealerAccId AND ClaimReason != null
                GROUP BY ClaimReason
                ORDER BY COUNT(Id) DESC
                LIMIT 8
            ];
        }

        /** Single-claim full-detail read. Caller MUST verify AccountId. */
        public List<Claim> readByIdForDetail(Id claimId) {
            return [
                SELECT Id, Name, AccountId, Status, Severity, Summary, ClaimReason,
                       EstimatedAmount, PartsEstimate__c, LaborEstimate__c,
                       InitiationDate, FinalizedDate, ApprovalDate__c,
                       ApprovedBy__c, ApprovedBy__r.Name,
                       RejectedBy__c, RejectedBy__r.Name,
                       Approver_Comments__c, RejectionReason__c, RootCause__c,
                       Risk_Score__c, AI_Recommendation__c, DealerCode__c,
                       RepairOrderNumber__c, FailureDescription__c, CorrectionDescription__c,
                       DiagnosticTroubleCode__c, MileageAtClaim__c, Vehicle_VIN__c,
                       Dealer_Response__c, Conversation_Log__c,
                       CreatedDate, LastModifiedDate
                FROM Claim WHERE Id = :claimId LIMIT 1
            ];
        }

        /** Read for dealer-response submit. Caller MUST verify AccountId. */
        public List<Claim> readByIdForResponse(Id claimId) {
            return [
                SELECT Id, Name, AccountId, Status, Summary, Severity, ClaimReason,
                       Dealer_Response__c, Conversation_Log__c
                FROM Claim WHERE Id = :claimId LIMIT 1
            ];
        }

        /** Lightest ownership-check probe. Caller MUST verify AccountId. */
        public List<Claim> readAccountId(Id claimId) {
            return [SELECT Id, AccountId FROM Claim WHERE Id = :claimId LIMIT 1];
        }

        /**
         * [v23.16] ContentDocumentLink list for a claim. Customer Community
         * Plus users have separate row-level CDL visibility that's
         * stricter than linked-entity sharing — even with the CDL
         * created at Visibility='AllUsers', the dealer can't see
         * OEM-uploaded files under `with sharing`. Caller MUST have
         * already access-checked the claim by AccountId before calling.
         */
        public List<ContentDocumentLink> listDocumentsForClaim(Id claimId) {
            return [
                SELECT ContentDocumentId, ContentDocument.Title, ContentDocument.FileType,
                       ContentDocument.ContentSize, ContentDocument.CreatedDate,
                       ContentDocument.CreatedBy.Name
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :claimId
                ORDER BY ContentDocument.CreatedDate DESC
                LIMIT 20
            ];
        }

        /**
         * [v23.18] Update a Claim row regardless of per-record sharing.
         * Required so dealer user A can respond to a claim filed by
         * dealer user B at the same dealership (status flip back to
         * 'Under Review' would fail under `with sharing`). Caller
         * MUST have already access-checked the claim by AccountId.
         */
        public void updateClaim(Claim c) {
            update c;
        }

        /**
         * [v23.20] Cash-flow status aggregate. ALL claims for the dealer,
         * regardless of period — the cash-flow pipeline is supposed to
         * reflect "where my money is right now in the warranty cycle"
         * which is a STATE question, not a time-window question. Each
         * row carries Status + count + total EstimatedAmount.
         */
        public List<AggregateResult> aggregateCashflow(Id dealerAccId) {
            return [
                SELECT Status status, COUNT(Id) cnt, SUM(EstimatedAmount) amt
                FROM Claim
                WHERE AccountId = :dealerAccId
                GROUP BY Status
            ];
        }
    }

    /**
     * Encapsulated `without sharing` helper for cross-dealer lookups. ONLY
     * used by lookupVIN to fetch the vehicle + asset + account chain across
     * dealer boundaries.
     */
    private without sharing class CrossDealerLookup {
        public VehicleProbe findVehicleByVin(String cleanVin) {
            String wildcard = '%' + cleanVin + '%';
            List<Vehicle> vl = [
                SELECT AssetId, VehicleIdentificationNumber, MakeName, ModelName,
                       ModelYear, ExteriorColor, LastOdometerReading
                FROM Vehicle
                WHERE VehicleIdentificationNumber = :cleanVin
                   OR VehicleIdentificationNumber LIKE :wildcard
                ORDER BY VehicleIdentificationNumber
                LIMIT 1
            ];
            if (vl.isEmpty()) return null;

            VehicleProbe p = new VehicleProbe();
            p.veh = vl[0];
            Date today = Date.today();
            if (p.veh.AssetId != null) {
                List<AssetWarranty> awl = [
                    SELECT AssetId, StartDate, EndDate, WarrantyType, WarrantyTerm.WarrantyTermName
                    FROM AssetWarranty WHERE AssetId = :p.veh.AssetId AND StartDate <= :today AND EndDate >= :today
                    ORDER BY EndDate DESC LIMIT 1
                ];
                if (!awl.isEmpty()) p.aw = awl[0];

                // Owning-dealer Account — only Account name + Id, no PII.
                List<Asset> assets = [
                    SELECT AccountId, Account.Name FROM Asset WHERE Id = :p.veh.AssetId LIMIT 1
                ];
                if (!assets.isEmpty()) {
                    p.ownerAcctId   = assets[0].AccountId;
                    p.ownerAcctName = assets[0].Account != null ? assets[0].Account.Name : null;
                }
            }
            return p;
        }
    }

    @AuraEnabled
    public static Map<String, Object> submitNewClaim(Map<String, Object> formData) {
        try {
            Id dealerAccId = getDealerAccountId();
            if (dealerAccId == null) throw new AuraHandledException('Unable to identify dealer account.');
            // [v22.1] VIN format enforcement lives in the LWC (user-typed entry
            // gets validated against WC_VinFormat.CANONICAL_REGEX). We don't
            // re-validate here — the dealer's existing fleet may carry legacy
            // 16-char VINs and we want fleet-picked submissions to still go
            // through. WC_VinFormat is wired into LWC and will be enforced
            // here once a one-time data migration normalizes legacy VINs.
            Map<String, Decimal> gst = computeGst(
                formData.containsKey('partsEstimate') ? Decimal.valueOf(String.valueOf(formData.get('partsEstimate'))) : null,
                formData.containsKey('labourEstimate') ? Decimal.valueOf(String.valueOf(formData.get('labourEstimate'))) : null
            );
            Claim newClaim = new Claim();
            newClaim.Name             = WC_ClaimNameGenerator.next();
            newClaim.AccountId        = dealerAccId;
            newClaim.ClaimReason      = (String) formData.get('category');
            newClaim.Summary          = (String) formData.get('summary');
            newClaim.Severity         = (String) formData.get('severity');
            newClaim.PartsEstimate__c  = gst.get('partsSubtotal');
            newClaim.LaborEstimate__c  = gst.get('labourSubtotal');
            newClaim.EstimatedAmount   = gst.get('total');
            newClaim.DealerCode__c     = (String) formData.get('dealerCode');
            newClaim.InitiationDate    = Date.today();
            newClaim.Status            = 'New';
            if (formData.containsKey('diagnosticCode'))
                newClaim.DiagnosticTroubleCode__c = (String) formData.get('diagnosticCode');
            if (formData.containsKey('mileage') && formData.get('mileage') != null)
                newClaim.MileageAtClaim__c = Decimal.valueOf(String.valueOf(formData.get('mileage')));
            if (formData.containsKey('failureDescription'))
                newClaim.FailureDescription__c = (String) formData.get('failureDescription');
            if (formData.containsKey('vin') && formData.get('vin') != null)
                newClaim.Vehicle_VIN__c = String.valueOf(formData.get('vin')).toUpperCase();
            insert newClaim;
            System.debug(LoggingLevel.FINE, 'WC_P15 claim created=***');

            // [P16] Auto-share with the dealer user so it shows up in the portal
            // immediately. Without this, the new claim is invisible to the dealer
            // because external OWD on Claim is Private and the existing 22 claims
            // were back-shared via a one-time script.
            try {
                insert new ClaimShare(
                    ParentId      = newClaim.Id,
                    UserOrGroupId = UserInfo.getUserId(),
                    AccessLevel   = 'Read',
                    RowCause      = 'Manual'
                );
            } catch (Exception shareErr) {
                System.debug(LoggingLevel.WARN, 'WC_P16 ClaimShare insert failed: ' + shareErr.getMessage());
            }

            return new Map<String, Object>{
                'success'     => true,
                'claimId'     => newClaim.Id,
                'claimNumber' => newClaim.Name,
                'totalAmount' => gst.get('total'),
                'gstAmount'   => gst.get('gst'),
                'message'     => 'Claim ' + newClaim.Name + ' submitted successfully.'
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    /**
     * [P17.x] submitDealerResponse — dealer answers an OEM "Requested Information"
     * by editing claim details and providing a response note.
     *
     * Allowed only when current Status is 'Requested Information'. After save,
     * status flips back to 'Under Review' so the OEM picks it up again. The PE
     * trigger fires on the status change → OEM's Approver Center sees the live
     * update.
     *
     * Editable fields scoped to the dealer's legitimate edit area:
     *   - Summary           (clarifying the issue)
     *   - Severity          (dealer can lower severity if reassessed)
     *   - ClaimReason       (re-classify the category)
     *   - Dealer_Response__c (free-text response/notes — required)
     */
    /**
     * [Issue 2] Dealer responds to OEM's "Requested Information" with editable
     * fields, a free-text response, and OPTIONALLY files (photos, docs).
     * Appends to Conversation_Log__c so both sides see the full history.
     * Flips status back to Under Review so OEM picks it up.
     */

    /**
     * [Q5] Change the current user's password from inside the dealer portal.
     * Wraps Site.changePassword which is Experience Cloud-only — for internal
     * Lightning context this method just returns an instruction to use the
     * standard Lightning personal-settings page (we don't expose admin password
     * resets to LWCs).
     *
     * Site.changePassword returns a PageReference on success and throws on
     * failure (wrong old password, weak new password, mismatch). We funnel
     * those into clean AuraHandledExceptions for the UI.
     */
    @AuraEnabled
    public static Map<String, Object> changePasswordForUser(
        String oldPassword, String newPassword, String confirmPassword
    ) {
        try {
            if (String.isBlank(oldPassword) || String.isBlank(newPassword) || String.isBlank(confirmPassword))
                throw new AuraHandledException('All three password fields are required.');
            if (newPassword != confirmPassword)
                throw new AuraHandledException('New password and confirmation do not match.');
            if (newPassword.length() < 8)
                throw new AuraHandledException('New password must be at least 8 characters.');
            if (newPassword == oldPassword)
                throw new AuraHandledException('New password must be different from the current password.');

            // Site.changePassword only works in Experience Cloud session context.
            // In internal Lightning, it throws — we catch and return a helpful message.
            try {
                System.PageReference pr = Site.changePassword(newPassword, confirmPassword, oldPassword);
                return new Map<String, Object>{
                    'success' => true,
                    'message' => 'Password changed successfully.'
                };
            } catch (Exception siteEx) {
                // Common cases: wrong old password, password complexity policy fail,
                // or running outside Experience Cloud.
                String em = String.valueOf(siteEx.getMessage());
                if (em != null && em.toLowerCase().contains('current password')) {
                    throw new AuraHandledException('Current password is incorrect.');
                }
                if (em != null && em.toLowerCase().contains('password')) {
                    throw new AuraHandledException(em);
                }
                throw new AuraHandledException(
                    'Password change is only available from the Experience Cloud site. ' +
                    'Use your global Setup → Personal Settings on internal Lightning.'
                );
            }
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    @AuraEnabled
    public static Map<String, Object> submitDealerResponse(
        Id claimId, String summary, String severity, String claimReason,
        String response, List<FileInput> files
    ) {
        try {
            if (claimId == null) throw new AuraHandledException('Claim ID required.');
            if (String.isBlank(response))
                throw new AuraHandledException('Please add a response note before resubmitting.');

            Id dealerAccId = getDealerAccountId();
            // [v23.14] Without-sharing read so any dealer user can respond
            // on behalf of the dealership; tenant boundary enforced below.
            List<Claim> owns = new DealerScopedClaimReader().readByIdForResponse(claimId);
            if (owns.isEmpty() || (dealerAccId != null && owns[0].AccountId != dealerAccId))
                throw new AuraHandledException('Access denied.');

            Claim c = owns[0];
            if (c.Status != 'Requested Information')
                throw new AuraHandledException(
                    'You can only respond when the claim is in "Requested Information" state. ' +
                    'Current status: ' + c.Status
                );

            // [Refinement] Attach files FIRST so the conversation entry reflects
            // the actual successful count rather than the requested count. Some
            // files may be rejected by MIME/magic-byte validation in
            // attachFilesToClaim and we don't want the log to overstate.
            Integer fileCount = (files == null) ? 0 : files.size();
            Integer attached = 0;
            List<String> fileErrors = new List<String>();
            if (fileCount > 0) {
                Map<String, Object> attachResult = attachFilesToClaim(c.Id, files);
                attached   = (Integer) attachResult.get('attachedCount');
                fileErrors = (List<String>) attachResult.get('errors');
            }

            // Build the conversation entry with the ACCURATE attached count.
            // When files are rejected, list each filename + reason so the OEM can ask
            // the dealer to re-upload in a supported format instead of guessing.
            String entryBody = response;
            if (attached > 0) {
                entryBody += '\n📎 ' + attached + ' file' + (attached > 1 ? 's' : '') + ' attached';
            }
            if (fileErrors != null && !fileErrors.isEmpty()) {
                entryBody += '\n⚠️ ' + fileErrors.size() + ' file' +
                    (fileErrors.size() > 1 ? 's' : '') + ' rejected:';
                for (String err : fileErrors) entryBody += '\n  • ' + err;
            }

            // Apply dealer edits (empty strings are ignored to prevent accidental clears)
            if (!String.isBlank(summary))     c.Summary     = summary;
            if (!String.isBlank(severity))    c.Severity    = severity;
            if (!String.isBlank(claimReason)) c.ClaimReason = claimReason;
            c.Dealer_Response__c   = response;
            c.Conversation_Log__c  = ClaimConversationService.appendEntry(
                c.Conversation_Log__c, ClaimConversationService.ROLE_DEALER, null, entryBody
            );
            // Flip back to OEM review so the approver picks it up again
            c.Status = 'Under Review';
            // [v23.18] Update via without-sharing helper so dealer user A
            // can respond on a claim filed by dealer user B (same Account).
            // Tenant boundary already enforced by the AccountId check above.
            new DealerScopedClaimReader().updateClaim(c);

            return new Map<String, Object>{
                'success'       => true,
                'claimId'       => c.Id,
                'newStatus'     => c.Status,
                'attachedCount' => attached,
                'fileErrors'    => fileErrors,
                'message'       => fileCount > 0
                    ? ('Response sent to OEM with ' + attached + ' file(s). Claim is back under review.')
                    : 'Response sent to OEM. Claim is back under review.'
            };
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    @AuraEnabled
    public static Map<String, Object> attachFilesToClaim(Id claimId, List<FileInput> files) {
        try {
            if (claimId == null || files == null || files.isEmpty())
                throw new AuraHandledException('Claim ID and files required.');
            Id dealerAccId = getDealerAccountId();
            // [v23.14] Without-sharing read so any dealer user can attach
            // files to claims at the dealership; tenant boundary enforced below.
            List<Claim> owns = new DealerScopedClaimReader().readAccountId(claimId);
            if (owns.isEmpty() || owns[0].AccountId != dealerAccId)
                throw new AuraHandledException('Access denied.');

            // Delegate the file plumbing (MIME allowlist + magic-byte check + ContentVersion
            // + ContentDocumentLink) to the shared service so dealer + OEM stay in lockstep
            // when we add new accepted formats. Convert local FileInput → service FileInput.
            List<WC_ClaimAttachmentService.FileInput> svcFiles = new List<WC_ClaimAttachmentService.FileInput>();
            for (FileInput f : files) {
                WC_ClaimAttachmentService.FileInput sf = new WC_ClaimAttachmentService.FileInput();
                sf.name = f.name; sf.mimeType = f.mimeType; sf.base64Data = f.base64Data;
                svcFiles.add(sf);
            }
            return WC_ClaimAttachmentService.attach(claimId, svcFiles);
        } catch (AuraHandledException ahe) { throw ahe; }
        catch (Exception e) { throw safe(e); }
    }

    private static List<ActivityEntry> buildTimeline(Claim c, List<DocumentInfo> docs) {
        List<ActivityEntry> tl = new List<ActivityEntry>();
        if (c.FinalizedDate != null) {
            ActivityEntry e = new ActivityEntry();
            e.ts = Datetime.newInstanceGmt(c.FinalizedDate.year(), c.FinalizedDate.month(), c.FinalizedDate.day(), 0, 0, 0);
            e.action = 'Claim finalised'; e.details = c.Status; tl.add(e);
        }
        if (c.ApprovalDate__c != null) {
            ActivityEntry e = new ActivityEntry();
            e.ts = Datetime.newInstanceGmt(c.ApprovalDate__c.year(), c.ApprovalDate__c.month(), c.ApprovalDate__c.day(), 0, 0, 0);
            e.action = 'Approved'; e.details = c.Approver_Comments__c; tl.add(e);
        }
        if (c.RejectionReason__c != null) {
            ActivityEntry e = new ActivityEntry();
            e.ts = c.LastModifiedDate; e.action = 'Rejected / Info Requested'; e.details = c.RejectionReason__c; tl.add(e);
        }
        if (c.InitiationDate != null) {
            ActivityEntry e = new ActivityEntry();
            e.ts = Datetime.newInstanceGmt(c.InitiationDate.year(), c.InitiationDate.month(), c.InitiationDate.day(), 9, 0, 0);
            e.action = 'Claim submitted'; e.details = 'Via Dealer Portal'; tl.add(e);
        }
        ActivityEntry created = new ActivityEntry();
        created.ts = c.CreatedDate; created.action = 'Claim created'; tl.add(created);
        for (DocumentInfo d : docs) {
            ActivityEntry e = new ActivityEntry();
            e.ts = d.uploadedAt; e.action = 'Document uploaded: ' + d.title; e.actor = d.uploadedBy; tl.add(e);
        }
        // [Issue 2] Add each conversation entry as a timeline event so the
        // dealer sees every back-and-forth exchange in chronological order.
        if (!String.isBlank(c.Conversation_Log__c)) {
            for (ClaimConversationService.Entry ent : ClaimConversationService.parseEntries(c.Conversation_Log__c)) {
                ActivityEntry e = new ActivityEntry();
                try { e.ts = (Datetime) JSON.deserialize('"' + ent.timestamp + '"', Datetime.class); }
                catch (Exception ignored) { e.ts = c.LastModifiedDate; }
                String roleLabel = ent.role == 'OEM' ? 'OEM' : (ent.role == 'DEALER' ? 'Dealer' : 'System');
                e.action  = roleLabel + ' note: ' + (ent.body != null && ent.body.length() > 80
                    ? ent.body.substring(0, 79) + '…' : ent.body);
                e.actor   = ent.author;
                e.details = null;
                tl.add(e);
            }
        }
        tl.sort();
        return tl;
    }

    // ─── Wrappers ────────────────────────────────────────────────────────

    public class DealerClaimWrapper {
        @AuraEnabled public Id      id;
        @AuraEnabled public String  name;
        @AuraEnabled public String  status;
        @AuraEnabled public String  severity;
        @AuraEnabled public String  summary;
        @AuraEnabled public String  category;
        @AuraEnabled public Decimal partsSubtotal;
        @AuraEnabled public Decimal labourSubtotal;
        @AuraEnabled public Decimal subtotal;
        @AuraEnabled public Decimal gstAmount;
        @AuraEnabled public Decimal totalAmount;
        @AuraEnabled public String  vin;
        @AuraEnabled public String  vehicleModel;
        @AuraEnabled public Integer vehicleYear;
        @AuraEnabled public Date    initiationDate;
        @AuraEnabled public Date    approvalDate;
        @AuraEnabled public Date    finalizedDate;
        @AuraEnabled public Integer daysSinceFiled;
        @AuraEnabled public Integer riskScore;
        @AuraEnabled public String  aiRecommendation;
        @AuraEnabled public String  dealerCode;
        @AuraEnabled public String  statusCss;
        @AuraEnabled public Integer pipelineStage;
        @AuraEnabled public String   approverComments;
        @AuraEnabled public Datetime lastModifiedDate;
    }

    // Separate class (Apex cannot extend non-virtual inner classes)
    public class DealerClaimDetailWrapper {
        @AuraEnabled public Id       id;
        @AuraEnabled public String   name;
        @AuraEnabled public String   status;
        @AuraEnabled public String   severity;
        @AuraEnabled public String   summary;
        @AuraEnabled public String   category;
        @AuraEnabled public Decimal  partsSubtotal;
        @AuraEnabled public Decimal  labourSubtotal;
        @AuraEnabled public Decimal  subtotal;
        @AuraEnabled public Decimal  gstAmount;
        @AuraEnabled public Decimal  totalAmount;
        @AuraEnabled public String   vin;
        @AuraEnabled public String   vehicleModel;
        @AuraEnabled public Integer  vehicleYear;
        @AuraEnabled public String   vehicleColor;
        @AuraEnabled public Integer  vehicleOdometer;
        @AuraEnabled public Date     initiationDate;
        @AuraEnabled public Date     approvalDate;
        @AuraEnabled public Date     finalizedDate;
        @AuraEnabled public Integer  daysSinceFiled;
        @AuraEnabled public Integer  riskScore;
        @AuraEnabled public String   aiRecommendation;
        @AuraEnabled public String   dealerCode;
        @AuraEnabled public String   repairOrderNumber;
        @AuraEnabled public String   failureDescription;
        @AuraEnabled public String   correctionDescription;
        @AuraEnabled public String   diagnosticCode;
        @AuraEnabled public Integer  mileageAtClaim;
        @AuraEnabled public String   warrantyCoverage;
        @AuraEnabled public Date     warrantyStartDate;
        @AuraEnabled public Date     warrantyEndDate;
        @AuraEnabled public String   approverComments;
        @AuraEnabled public String   rejectionReason;
        @AuraEnabled public String   dealerResponse;
        // [v22.4] Decision attribution — branded "Atlas AI Triage" label
        // when no human is stamped on ApprovedBy__c / RejectedBy__c.
        @AuraEnabled public String   decidedByName;
        @AuraEnabled public Boolean  decidedByAutoTriage;
        @AuraEnabled public List<ClaimConversationService.Entry> conversation;
        @AuraEnabled public String   statusCss;
        @AuraEnabled public Integer  pipelineStage;
        @AuraEnabled public Datetime createdDate;
        @AuraEnabled public List<DocumentInfo>  documents;
        @AuraEnabled public List<ActivityEntry> activityTimeline;
    }

    public class VehicleWrapper {
        @AuraEnabled public Id      assetId;
        @AuraEnabled public String  vin;
        @AuraEnabled public String  make;
        @AuraEnabled public String  model;
        @AuraEnabled public Integer year;
        @AuraEnabled public String  color;
        @AuraEnabled public Integer odometer;
        @AuraEnabled public String  warrantyStatus;
        @AuraEnabled public String  warrantyType;
        @AuraEnabled public Date    warrantyEndDate;
        @AuraEnabled public Integer daysToExpiry;
        @AuraEnabled public Integer mileagePct;
        @AuraEnabled public String  statusCss;
        @AuraEnabled public Integer priorClaimsCount;
        // Cross-dealer service support: who registered the vehicle, and is
        // the current logged-in dealer different from the registering dealer.
        @AuraEnabled public Id      ownerDealerAccountId;
        @AuraEnabled public String  ownerDealerName;
        @AuraEnabled public Boolean crossDealer;
    }

    public class FileInput {
        @AuraEnabled public String name;
        @AuraEnabled public String mimeType;
        @AuraEnabled public String base64Data;
    }

    public class DocumentInfo {
        @AuraEnabled public Id       contentDocumentId;
        @AuraEnabled public String   title;
        @AuraEnabled public String   fileType;
        @AuraEnabled public Long     sizeKb;
        @AuraEnabled public Datetime uploadedAt;
        @AuraEnabled public String   uploadedBy;
        @AuraEnabled public String   icon;          // [v23] computed emoji per file type
        @AuraEnabled public String   downloadUrl;   // [v23] /sfc/servlet.shepherd/...
    }

    public class ActivityEntry implements Comparable {
        @AuraEnabled public Datetime ts;
        @AuraEnabled public String   actor;
        @AuraEnabled public String   action;
        @AuraEnabled public String   details;
        public Integer compareTo(Object other) {
            ActivityEntry o = (ActivityEntry) other;
            if (ts == null && o.ts == null) return 0;
            if (ts == null) return 1; if (o.ts == null) return -1;
            return o.ts > ts ? 1 : (o.ts < ts ? -1 : 0);
        }
    }
}