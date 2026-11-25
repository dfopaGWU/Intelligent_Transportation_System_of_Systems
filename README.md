This is an agent-based NetLogo model of a one-way, three-lane expressway carrying a mix of human-driven vehicles (HVs) and Level 2 connected and autonomous vehicles (CAVs). It’s used to study how the share of CAVs, called the market penetration rate (MPR), affects traffic efficiency at different demand levels.
The model is built around the two efficiency measures in Song et al. (2023), “Impacts of Connected and Autonomous Vehicles with Level 2 Automation on Traffic Efficiency and Energy Consumption” (Journal of Advanced Transportation):
Average travel time (ATT): the mean time from when a vehicle arrives until it leaves the road, including any wait at the entrance.
Actual road capacity (Qr/Qi): the real flow rate divided by the input flow rate.
CAVs differ from HVs in two ways. They keep a shorter time gap to the car ahead, and they never brake at random. HVs follow a Nagel–Schreckenberg-style random-slowdown rule. Demand is set as a percentage of the all-HV road capacity, so every MPR faces the same traffic and the CAV effect can be isolated.
Beyond Song’s setup, the model adds three features that can each be switched on separately:
Changing weather by zone, which lowers vehicle speeds.
Road Weather Information System (RWIS) warnings, which let CAVs see weather further ahead.
An adaptive ramp meter at an on-ramp, which responds to mainline density.
It’s a simplified model that captures the mechanisms and trends Song describes, not a replica of the paper’s VISSIM simulation. Distances are in patches and time in ticks (1 tick = 1 second), and patches haven’t been calibrated to real distances. So the results should be compared on trends and relative change, not exact values.
The existing “What this model does” notes in your Info tab mention a 4 km road, 0.6 s / 1.2 s headways, and dedicated CAV lanes. None of those match the current code: the road is 250 patches, the headways are 0.5 and 2.0, and the cav-lanes slider isn’t used. Update or delete those notes so the Info tab matches what the model actually does.
