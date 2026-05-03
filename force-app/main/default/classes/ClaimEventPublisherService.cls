/**
 * Pure-function builder for Warranty_Claim_Event__e records. Extracted from the
 * ClaimEventPublisher trigger so the event-building logic can be unit-tested
 * without DML or async event-bus flushes.
 *
 * The trigger is responsible for the side effect (EventBus.publish). This class
 * only constructs and returns the events.
 */
public with sharing class ClaimEventPublisherService {

    /** Build the platform events that should fire for a given trigger pass.
     *  @param newRecords  Trigger.new (insert) or Trigger.new (update)
     *  @param oldMap      Trigger.oldMap on update; null/empty on insert
     *  @param op          Trigger.operationType (only AFTER_INSERT and AFTER_UPDATE produce events)
     *  @return            zero or more events to publish; never null. */
    public static List<Warranty_Claim_Event__e> buildEvents(
        List<Claim> newRecords, Map<Id, Claim> oldMap, TriggerOperation op
    ) {
        List<Warranty_Claim_Event__e> events = new List<Warranty_Claim_Event__e>();
        if (newRecords == null || newRecords.isEmpty()) return events;

        if (op == TriggerOperation.AFTER_INSERT) {
            for (Claim c : newRecords) {
                events.add(toEvent(c, null, 'NEW'));
            }
        } else if (op == TriggerOperation.AFTER_UPDATE) {
            // Fire on:
            //   1. Status change                    → 'STATUS_CHANGE'
            //   2. Approver_Comments__c added/changed → 'COMMENT_ADDED'
            //   3. RejectionReason__c added         → 'COMMENT_ADDED' (denial reason is a kind of comment)
            // (1) and (2)/(3) can both fire for the same record in the same edit;
            // the dealer should see distinct notifications for each.
            for (Claim c : newRecords) {
                Claim before = (oldMap == null) ? null : oldMap.get(c.Id);
                if (before == null) continue;
                if (c.Status != before.Status) {
                    events.add(toEvent(c, before.Status, 'STATUS_CHANGE'));
                }
                Boolean commentChanged =
                    !String.isBlank(c.Approver_Comments__c)
                    && c.Approver_Comments__c != before.Approver_Comments__c;
                Boolean rejectionAdded =
                    !String.isBlank(c.RejectionReason__c)
                    && c.RejectionReason__c != before.RejectionReason__c;
                if (commentChanged || rejectionAdded) {
                    // Send a separate event so the dealer's bell increments
                    // even when the OEM only added a note without changing status.
                    events.add(toEvent(c, before.Status, 'COMMENT_ADDED'));
                }
            }
        }
        return events;
    }

    private static Warranty_Claim_Event__e toEvent(Claim c, String previousStatus, String eventType) {
        return new Warranty_Claim_Event__e(
            Event_Type__c        = eventType,
            Claim_Id__c          = c.Id,
            Claim_Number__c      = c.Name,
            Claim_Status__c      = c.Status,
            Previous_Status__c   = previousStatus,
            AI_Recommendation__c = c.AI_Recommendation__c,
            Channel__c           = c.Channel__c,
            Risk_Score__c        = c.Risk_Score__c,
            Estimated_Amount__c  = c.EstimatedAmount,
            Dealer_Account_Id__c = c.AccountId
        );
    }
}