# Get_Next_Free_Provider_Schedule

Finds the next free time slot to schedule for a Cancer Center Provider using Mosaiq

UNMCCC uses Mosaiq's guidelines or templates in a way that deviates a bit from Elekta's expectations.
Thus, Elekta's built-in function to find next avail slot does not work.

In this repo, you'll find the framework to get that next appointment.  This will be based on the
already booked times, and the guidelines existing and well, non-existing.

For this, we need the schedule and the templates.  We need to build the time ranges where we can slot in 
a patient.

It will not be perfect, but the hope is that we will get it right most of the time.

UNMCC Patient Services (Athena, Maria, Katybeth, Jamie) assisting, as well as Inigo's team and ofc Claude)

# Templates or Guidelines

Our templates may be incomplete (not span all the times for all the providers)
Our templates may have not or may have incomplete rule-based guidance.
Our templates do not have a super easy way to tell whether they are blocking, or guiding (free-slots) or 
open but restricted. We mostly rely on pattern matching (these are words encountered in blocking guidelines: MEETING, NOT IN CLINIC, OUT OF CLINIC, PTO, DO NOT BOOK, CLOSED, VACATION, BLOCK, ANNUAL LEAVE,...). 
Oddities about descriptions: HOT SPOT -- this tells the scheduler take this slot only if you filled all other slots. 
Sometimes, guidelines are about what type of encounters the provider wants in certain slots: Like, pre-chemos first thing in the morning -- i.e; specificity in type of activity. Sometimes there is guidance as for max number of patients in the guideline.  In this 2 hours, only 6 patients (regardless whether it is five OV20 and one NP30).  This may be too greedy to encode, specially since the RuleLimit is seldom used.

The structure (that matters) about our templates:

dbo.SchTempl
  - PK : a primary key
  - Create_id : creator id
  - Create_DtTm : date first created
  - Edit_id  : last staff editing
  - Edit_DtTm  : date when last edited
  - TemplateDesc : A free text synopsis of the guideline (NP 60) Note, this used to understand nature of template.
  - TemplateType : Integer for classifying guidelines (1-Holiday, 2-Leave, 3-Prof Leave, 4-Clinic Hours, 6-Custom (we use 6 heavily for all things, but some in 1-2-3)
  - Freq_Type : dictates the first of four+ types of frequency (Integer, powers of 2 to denote: Daily, Weekly, Monthly-A, Monthly-B some combos)
  - Freq_Interval : depending on Freq_Type context, a number that indicates days, or "first", etc
  - Freq_Relative_Intervale : For nested frequencies, may indicate day-of-week, or something like that.
  - Freq_Recurrence_Factor : Aids complex frequencies when needed (see below for full coverage).
  - DefaultResource: Integer to denote target of guideline: 1-All, 5-Staff (Specific), 7-Location(Specific). Those are almost only ones used.
  - PRS_ID: Unused activity code for DefaultResource that are almost never used.
  - Staff_Staff_ID: the ID of the provider referred in a template of DefaultResource=5. Points to Staff.Staff_id, or derived table with same content.
  - TemplRule: Integer denoting whether is Max Appointments (=2) per guideline, Max Conflicts, and so forth
  - RuleLimit: Relative to the TemplRule, if there is a limit "Max Appointments : 5". The integer is the value.
  - Priority: Important integer. Indicates the priority that dictates which guideline wins.  Lower integers->lower priority, lose to higher priority.
  - TemplColor : A color, used in the app to fill cells governed by this guideline
  - Disabled : When 0, this is active, otherwise, obsolete
  - TemplStartDate: Integer storing the start date of the template. I never saw it null
  - TemplStartTime: Integer storing the start time of the guideline. I never saw it null
  - TemplEndDate : when not null, this integer is the end date. Otherwise (null) represents guidelines with end date same as start date.
  - TemplEndTime : Integer storing the end time of the guideline. I never saw it null 

Frequencies represented by these four fields echo the guidelines over the calendar.  Encoding with Examples:
* Freq_Type = 2^2   Every X days, where X is stored in freq_Interval.   Every 3 days:  freq_type=4;freq_interval=3,freq_relative_interval=0;freq_recurrence_factor=0
* Freq_Type = 2^3   Every X weeks, with checkboxes for Mon-Tue-..-Sun.  freq_recurrence_factor is X and in freq_Interval, an integer from 1 to 128 or so, 76 diff values.
                     Here is the trick.  Sun=2^0, Mon=2^1,...,Sat=2^6.
                     Need an example here.
* Freq_Type = 2^4   The X of every Y Months.  
                     - Freq_interval is X; 
                     - Freq_relative_interval is zero, does not apply; 
                     - Freq_recurrent_Interval is Y.  
                     - Example : The 1 of every 2 months (16,1,9,2)
* Freq_Type = 2^5   The X dayOfWeek Y of every Z months (as in the second thursday of every 2 months).                   
                     - Freq_interval is Y (1-Sunday,…,7-Saturday)
                     - Freq_relative_Intervals is X First, Second, ..,Last=5
                     - Freq_recurrence_factor is Z  
                     - Example : the Third Sunday of every 3 months (32,1,3,3)
* Freq_Type = 2^6   The X of Y (month) (as in the 15 of February)
                     - Freq_interval is the X, the day, from 1 to 31ish
                     - Freq_relative_interval (Not applies, 0)
                     - Freq_recurrent_Factor is Y (the number of the month: 5-may)
                     - Example: The 15 of February.  (64,15,0,2)
* Freq_Type = 2^7   The X of [DayOfWeek] of [Month] (as in the last sunday of May)      
                     - Freq_Interval is [DayOfWeek] (1-Sunday,…,7-Saturday)
                     - Freq_relative_Interval is X  (first-1, second-2,..,last-5)
                     - Freq_recurrent_factor is [Month] (the number of the month – May-5)
                     - Example The last Sunday of May (128,1,5,5)
                     
These frequencies apply to extrapolate a template along the calendar
    A guideline CCIR30min starts on Aug-2-2021 with no end date, for Dr. Kumar from 10am to 11am every Thurs (8,16,1,0) -- it will appear on Kumar Calendar on Thurdays at 10am for the foreseable.

When twp or more guidelines overlap in the calendar, the one with the highest priority wins. Thus, the "general" hospital hours have low priority, a default of sort.  Holidays have high priority to block those days.  Non-Blocking Clinic Hours have some of the highest relative priorities too.

We should only be concerned with active guidelines (Disabled=0)

## About Template Rules
Known TemplRule values (from a 2026 audit of prod SchTempl):

| TemplRule | Name                                    | Uses RuleLimit? | Uses PRS_ID (activity)?  | Prod instances |
|-----------|-----------------------------------------|-----------------|--------------------------|-----------------|
| 2         | Maximum Appointments                    | Yes             | No                       | 20,815          |
| 1         | Maximum Conflicts                       | Yes             | No                       | 936             |
| 9         | Only Appointments with This Activity    | No (Limit=0)    | Yes                      | ~800            |
| 12        | Maximum Appointments With This Activity | Yes             | Yes                      | 16              |
| 5         | Maximum Appointments of Status          | Yes             | No, but uses Sch.Status  | 41              |
| 7         | Only Patients of Status                 | No (Limit=0)    | No, but links to pat stat| 18              |
| 8         | Only Appts of Status                    | Yes             | No, but sch.status link  | 0               |
| 10        | Maximum Appointments with Diagnosis     | Yes             | No, but tpg.code link    | 0               |
| 3         | Maximum Appointments of Payer Type      | Yes             | No, but yuck             | 0               |

Note on RuleLimit=0: on Vacation/Holiday/Prof-Leave templates (TemplateType 1/2/3),
Max Appointments is FORCED to Limit=0, and that 0 is meaningful -- it's the
mechanism that blocks all scheduling. On Custom templates (TemplateType 4/6),
RuleLimit is frequently left at 0 simply because it was never configured by the
guideline author, and should be treated as "no limit," not "zero appointments."
Downstream logic should scope the "0 = unlimited" interpretation to
TemplateType 4/6 only.

# Schedule (what times are already booked)

 A simplistic look at future appointments captured in a view
 
 dbo.vw_ScheduleNormalized
  - Provider (last name, First Name) of an active provider that can be scheduled, retrived from derived dataset
  - Activity (OV20, NP60..) a code to indicate what is the encounter about. Office visit 20 minutes, New Patient 60 minutes, etc.
  - StartDateTime. The date and time when the encounter or visit starts.
  - EndDateTime.  Based on the duration, when the appointment is supposed to end.

 This can be combined with the guidelines to have a complete picture of a provider's future calendar.

 We use these functions to calculate the windows of open time slots, and how to retrieve the next (few) available time slots.
