So for reworked command and control:

You can give any unit an order at any time. But for each order there is a transmission phase, and an planning phase, before the action actually begins (they're called something different at the moment).

# Isolated units (not under any HQ)

Factions have an "isolated_initiative" score. You can issue a single way-point move or attack order to an isolated unit, and an RNG check against its initiative will allow it to transmit immediately (Using intiative).

Factions also have a "can_use_runners" boolean. If the initiative check fails, the order will stay transmitting for 4 minutes per 500m hex (essentially simulating a running messenger) from the nearest HQ.

If you don't have "can_use_runners" and you fail your intiative check, you can't receive new orders for a baseline of 15 minutes, increased significantly by low morale.

In general, being isolated reduces morale.

[Not for implimentation yet - allow using digital consumer comms for a 5 minutes transmission if initiative fails, but will cause the unit to be exposed to factions with Digital Surveillance enabled].

# Units under an HQ

Factions have a default HQ orders transmission delay. The delay increases very significantly if the HQ is supressed, moderatly longer if mobile. The two stack.

If the HQ is in an unbroken overlapping communications chain to the top-level HQ (and it still exists) then order transmission is buffed significantly.

# Direct line of site

Direct line of site order transmission time is buffed further (along with the other buffs to accuracy, reduced supression, improved morale). They're basically instantaneous at this point.

# Planning time

Let's make ambush and patrol orders take a fair bit more planning than move orders or attack orders.

Planning time gets a buff from HQ line of site, and a further buff from unbroken chain back to brigade HQ.

# Changing HQ

Moving out of the range of your HQ puts you into the isolated state. Moving into a new HQs range takes 10 minutes to connect with HQ, and adding an order in this time, you have to wait for the connecting status to clear before the transmitting status even starts.

# General

All these buffs etc should be configurable for the factions, for the scenario etc.
