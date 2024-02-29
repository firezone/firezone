defmodule Domain.NameGenerator do
  @adjectives ~w(
    able absolute adorable adventurous academic acceptable acclaimed accomplished
    accurate active actual adept admirable admired adorable adored advanced affectionate
    agile alert amazing ambitious ample amused amusing anchored angelic animated
    annual antique anxious appropriate apt aromatic artistic assured astonishing
    athletic attentive attractive authentic authorized automatic average aware awesome
    awkward babyish back basic beautiful beloved beneficial best bewitched big
    big-hearted biodegradable bite-sized black black-and-white bland blank blaring
    blissful blond blue blushing bold bony bossy both bouncy bountiful brave
    brief bright brilliant brisk bulky bumpy buoyant bustling busy buttery buzzing
    calm candid capital carefree careful caring cautious celebrated charming cheap cheerful
    cheery chief classic clean clear clever close cloudy committed compassionate competent
    complete complex composed concerned confident concrete confident considerate constant
    content conventional cool cooperative coordinated crafty creamy creative crisp critical
    crowded cuddly cultured curious curvy cute cylindrical daring dark dazzling dear
    decent decisive dedicated deep defensive defiant delightful dense dependable
    detailed determined devoted different diligent direct discrete disciplined discreet
    distinguished diverse dramatic dreamy durable dynamic eager earnest easy easy-going
    eclectic educated efficient elaborate electric elegant elite eloquent elusive
    eminent emotional enchanted enchanting energetic enlightened enormous enthusiastic
    entire envious equal essential esteemed ethical euphoric even everlasting excellent
    exemplary excited exciting exotic experienced expert extraordinary exuberant fabulous
    fair faithful famous fancy fantastic far-sighted fascinating fast fearless
    feisty festive fiery fine firm first-class fit flamboyant flashy flawless
    flexible flourishing fluid focused fond forceful formal fortunate fragrant frank
    free fresh friendly frugal fruitful full functional funny futuristic gallant
    generous gentle genuine giant gifted giving glamorous gleaming gleeful glittering
    glorious glossy glowing golden good-natured gorgeous graceful gracious grand
    grateful great green gregarious handsome happy hardworking harmonious hearty
    heavenly hefty helpful heroic high-quality hilarious honest honorable hopeful
    hospitable hot huge humble humorous ideal imaginative immaculate impeccable
    important impressive improved inclusive independent industrious innovative
    insightful inspiring integral intelligent intense intentional interesting
    intuitive inventive invigorating joyful jubilant judicious keen kind kindhearted
    knowledgeable large lasting lavish leading lean learned legendary light lively
    logical lovable lovely loving loyal luminous luxurious magnificent majestic
    major male manageable manual many marvelous masculine massive mature
    meaningful meditative melodic memorable merry methodical meticulous mighty
    mindful minimal modern modest modular moral motivated multifaceted multitalented
    muscular musical mutual mysterious mystical natural navigable neat necessary
    neutral new nice nimble noble nocturnal normal notable noteworthy novel
    nurturing objective obliging observant obvious occasional optimistic opulent
    orderly organic original outgoing outstanding oval overjoyed palatable
    passionate patient peaceful perfect perpetual persistent personal persuasive
    philosophical pioneering placid playful pleasant pleasing plump polished polite
    popular positive powerful practical pragmatic precious precise preferred
    prepared presentable prestigious pretty proactive productive professional
    proficient progressive prominent promising prompt proper protective proud
    prudent punctual pure purposeful quaint qualified quick quiet radiant
    rational realistic reasonable reassuring receptive refined reflective
    refreshing regal regular reliable remarkable resilient resolute resourceful
    respectful responsible responsive restorative restrained revolutionary rich
    right robust romantic royal rustic safe sane satisfying scholarly scientific
    scrupulous secure sedate selective self-assured self-reliant sensible sensitive
    serene serious sharp shiny simple sincere skilled sleek smart smiling smooth
    snappy sociable soft solid sophisticated sparkling special spectacular spirited
    spiritual splendid spontaneous sporty stable steadfast steady strategic
    striking strong studious stunning stylish successful succinct suitable
    super superb superior supportive supreme sure-footed sustainable sweet
    sympathetic systematic tactical talented tasteful team tenacious tender
    thoughtful thriving tidy timeless tireless tolerant tough tranquil transcendent
    transformative transparent travel-savvy triumphant trustworthy
    understanding unique united universal upbeat upright useful valiant valuable
    versatile vibrant victorious vigilant vigorous virtuous visionary vital
    vivacious warm welcoming well-balanced well-behaved well-developed well-educated
    well-established well-informed well-intentioned well-respected well-rounded
    well-spoken whimsical willing wise witty wonderful worldly young youthful
    zealous zesty
  )
  @nouns ~w(
    ability access accomplishment accuracy achievement adaptation addition adjustment
    advancement adventure advice affiliation agency agility agreement aid aim
    alertness alliance allocation allowance alteration ambition analysis anchor
    angle anticipation application appraisal approach approval aptitude area
    arrangement art aspect aspiration assessment assistance assurance atmosphere
    attention attitude attribute audience authority automation availability
    balance barrier base basis benefit blueprint bond bonus boost boundary
    breakthrough budget buffer build building capability capacity capital
    care career caution certainty challenge change channel charge checkpoint
    choice circumstance clarity class classification clearance coalition code
    coherence collaboration comfort commitment communication community comparison
    competence competition component comprehension concentration concept
    concern conclusion condition conduct confidence configuration confirmation
    connection consensus consequence consistency consolidation constraint
    construction consultation contact containment content context contingency
    continuity contract contrast control convention conversion coordination
    core cornerstone correction correlation cost counsel countermeasure courage
    course coverage craft creativity credit criterion criticality crossroad
    culture currency curve cushion data deadline debate debt decision declaration
    decrease defense definition delegation delivery demand demonstration
    density department deployment depth design desire determination development
    device diagnosis dialogue dimension direction discipline discovery discretion
    discussion display distinction distribution diversity division domain
    dominance drive duty dynamism ease effectiveness efficiency effort elegance
    element elevation emphasis employment empowerment enablement enactment
    encounter endeavor endorsement energy engagement enhancement enterprise
    entertainment enthusiasm entity environment equality equation equilibrium
    equipment equity equivalence escalation essence estimation ethics evaluation
    event evidence evolution examination example excellence exception exchange
    excitement execution exercise expansion expectation expedition expense
    experience expertise explanation exploration exposure expression extension
    extent fabric facility factor faculty fairness faith fame feasibility feature
    feedback field figure flexibility focus force forecast formation foundation
    framework freedom function functionality funding fusion future gain gateway
    generation genius goal governance grace grade gradient grant gratitude
    ground growth guarantee guidance habit hallmark harmony headline health
    hearing heart height heritage hierarchy highlight horizon hypothesis
    identification identity ideology illumination illustration image impact
    implementation implication importance improvement impulse incentive inception
    inclusion income increase independence indicator induction industry influence
    information initiative innovation input inquiry insight inspection inspiration
    installation instance instinct institution instruction instrument integration
    integrity intelligence intention interaction interest interface interpretation
    intervention intuition invention inventory investigation investment invitation
    involvement issue item journey judgment junction justification kernel key
    knowledge landmark language launch law layer layout leadership learning
    legacy legislation liberty license life light limitation line link
    literacy literature logic longevity loop loyalty magnitude maintenance
    management mantra margin mark market mastery material matter means measure
    mechanism mediation medium membership memory mention merger message method
    metric milieu milestone mind mine mission model moderation momentum monitor
    motivation movement navigation network novelty objective observation
    obstacle option order organization orientation origin outcome outlook
    output outreach oversight pace pact parameter participation partnership
    passage passion path pattern pause payoff perception performance period
    permission perspective phase phenomenon philosophy pillar pioneer plan
    platform policy position possession possibility potential practice precision
    premise preparation presence presentation preservation prestige principle
    priority privacy privilege procedure process procurement productivity
    profession profile progress projection promise promotion proportion proposal
    prospect protection protocol provision proximity psychology publication
    pulse purpose quality quantity query quest question queue quickness quotation
    radar range rate rationale reaction readiness reality reason reassessment
    recognition recommendation reconciliation record recovery recruitment
    reduction reference reflection reform regard regulation reinforcement
    relation relationship relaxation release relevance reliability relief
    remedy remembrance renewal repair repetition replacement report representation
    repository requirement research resilience resolution resource response
    responsibility restoration result retention retrieval return revelation
    revenue review revision rhythm right rigor role routine rule safety
    sanction satisfaction scale scenario scene schedule scheme scholarship
    scope scrutiny search season sector security selection sensation sense
    sensitivity sentiment sequence series service session setup severity
    shape shift showcase significance similarity simplification simulation
    site situation skill solution sophistication source space span spectrum
    speed sphere spirit stability standard standpoint start statement station
    status strategy strength structure study style subject submission substance
    success suggestion summary supply support surface surveillance survey
    sustainability symbol symmetry synergy system tactic talent target task
    team technique technology temperament tendency tension term territory
    testament theory threshold tolerance topic tradition traffic trajectory
    transaction transformation transition transparency transport trend trial
    tribute trust truth understanding undertaking unity update upgrade uplift
    usage use utility validity value variation variety vector venture version
    view vision vitality volume voyage warranty wave wealth welfare will
    wisdom wit work workforce workshop world yield zone
  )

  def generate do
    "#{Enum.random(@adjectives)}-#{Enum.random(@nouns)}"
  end

  def generate_slug do
    generate()
    |> String.replace(~r/-/, "_")
  end
end
