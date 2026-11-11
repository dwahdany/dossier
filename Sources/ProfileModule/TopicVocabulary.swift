import Foundation

/// English labels for the fixed vocabulary of the system's high-level text topic model.
///
/// The vocabulary is the id table at the end of `highLevelTextTopics.dat` in the
/// PersonalizationPortraitInternals framework (784 generic Wikidata concepts, the same on
/// every Mac — not personal data). The file ships ids only, so the public Wikidata labels
/// of exactly that vocabulary are compiled in here; nothing is looked up at runtime.
/// Generated table: one `<QID><TAB><label>` pair per line.
enum TopicVocabulary {
    static let origin = "built-in topic vocabulary"

    static let labels: [String: String] = {
        var out: [String: String] = [:]
        out.reserveCapacity(784)
        for line in table.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            out[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return out
    }()

    private static let table = """
Q2	Earth
Q3	life
Q15	Africa
Q16	Canada
Q17	Japan
Q20	Norway
Q22	Scotland
Q28	Hungary
Q29	Spain
Q30	United States
Q31	Belgium
Q32	Luxembourg
Q33	Finland
Q34	Sweden
Q35	Denmark
Q36	Poland
Q37	Lithuania
Q38	Italy
Q39	Switzerland
Q40	Austria
Q43	Turkey
Q44	beer
Q45	Portugal
Q46	Europe
Q48	Asia
Q51	Antarctica
Q55	Netherlands
Q68	computer
Q75	Internet
Q79	Egypt
Q94	Android
Q95	Google
Q96	Mexico
Q111	Mars
Q142	France
Q144	dog
Q148	People's Republic of China
Q152	fish
Q155	Brazil
Q159	Russia
Q183	Germany
Q189	Iceland
Q190	God
Q193	Saturn
Q197	airplane
Q222	Albania
Q227	Azerbaijan
Q229	Cyprus
Q235	Monaco
Q241	Cuba
Q249	wireless communication
Q252	Indonesia
Q258	South Africa
Q262	Algeria
Q282	wine
Q289	television
Q290	sex
Q309	history
Q312	Apple Inc.
Q321	Milky Way
Q333	astronomy
Q334	Singapore
Q336	science
Q349	sport
Q362	World War II
Q388	Linux
Q395	mathematics
Q398	Bahrain
Q413	physics
Q418	telecommunications
Q420	biology
Q421	unidentified flying object
Q423	North Korea
Q432	Islam
Q458	European Union
Q466	World Wide Web
Q482	poetry
Q514	anatomy
Q523	star
Q634	planet
Q638	music
Q668	India
Q718	chess
Q726	horse
Q727	Amsterdam
Q729	animal
Q748	Buddhism
Q750	Bolivia
Q756	plant
Q794	Iran
Q796	Iraq
Q800	Costa Rica
Q801	Israel
Q805	Yemen
Q810	Jordan
Q817	Kuwait
Q836	Myanmar
Q837	Nepal
Q843	Pakistan
Q847	tennis
Q851	Saudi Arabia
Q858	Syria
Q864	Pokémon
Q865	Taiwan
Q872	radio
Q878	United Arab Emirates
Q881	Vietnam
Q889	Afghanistan
Q897	gold
Q924	Tanzania
Q944	quantum mechanics
Q954	Zimbabwe
Q974	Democratic Republic of the Congo
Q1004	comic
Q1016	Libya
Q1028	Morocco
Q1033	Nigeria
Q1045	Somalia
Q1049	Sudan
Q1057	metabolism
Q1063	evolution
Q1065	United Nations
Q1069	geology
Q1073	brain
Q1107	anime
Q1299	The Beatles
Q1344	opera
Q1368	money
Q1420	car
Q1519	Abu Dhabi
Q1563	Havana
Q1734	volleyball
Q1932	space race
Q1968	Formula One
Q2095	food
Q2269	Industrial Revolution
Q2329	chemistry
Q2539	machine learning
Q2736	association football
Q2743	musical play
Q2766	iPhone
Q2811	submarine
Q3559	comet
Q3918	university
Q3966	computer hardware
Q5043	Christianity
Q5113	bird
Q5367	motorsport
Q5369	baseball
Q5372	basketball
Q5375	cricket
Q5378	rugby
Q5386	auto racing
Q5389	Olympic Games
Q5891	philosophy
Q5994	piano
Q6206	capitalism
Q6216	liberalism
Q6235	nationalism
Q6388	swimming
Q6661	French cuisine
Q7075	library
Q7108	biotechnology
Q7162	genetics
Q7163	politics
Q7173	marine biology
Q7174	democracy
Q7202	molecular biology
Q7204	Middle East
Q7205	paleontology
Q7215	virology
Q7252	feminism
Q7257	ideology
Q7264	Marxism
Q7272	socialism
Q7291	badminton
Q7358	clown
Q7397	software
Q7590	transport
Q7735	diving
Q7749	rock and roll
Q7802	bread
Q7889	video game
Q7937	climate
Q7942	global warming
Q7944	earthquake
Q8008	Earth science
Q8065	natural disaster
Q8076	video game console
Q8134	economics
Q8142	currency
Q8161	tax
Q8242	literature
Q8253	fiction
Q8274	manga
Q8341	jazz
Q8355	violin
Q8366	algorithm
Q8434	education
Q8458	human rights
Q8461	racism
Q8473	military
Q8486	coffee
Q8502	mountain
Q8646	Hong Kong
Q8676	American Civil War
Q8683	Cold War
Q8789	cryptography
Q9089	Hinduism
Q9135	operating system
Q9174	religion
Q9268	Judaism
Q9350	yoga
Q9418	psychology
Q9448	Premier League
Q9730	classical music
Q9734	symphony
Q9759	blues
Q10294	poverty
Q10922	hardcore punk
Q11012	robot
Q11016	technology
Q11023	engineering
Q11030	journalism
Q11033	mass media
Q11180	internal medicine
Q11190	medicine
Q11366	alternative rock
Q11399	rock music
Q11406	electromagnetism
Q11409	apartheid
Q11410	game
Q11417	martial arts
Q11420	judo
Q11422	toy
Q11424	film
Q11425	animation
Q11442	bicycle
Q11451	agriculture
Q11460	clothing
Q11468	nanotechnology
Q11629	painting
Q11631	astronaut
Q11633	photography
Q11634	art of sculpture
Q11635	theatre
Q11639	dance
Q11660	artificial intelligence
Q11661	information technology
Q11663	weather
Q11690	Wall Street
Q11691	stock exchange
Q11707	restaurant
Q11756	prehistory
Q11995	pregnancy
Q12078	cancer
Q12128	dentistry
Q12133	deafness
Q12135	mental disorder
Q12136	disease
Q12140	medication
Q12147	health
Q12174	obesity
Q12206	diabetes
Q12271	architecture
Q12483	statistics
Q12554	Middle Ages
Q12585	Latin America
Q12684	fashion
Q12739	nuclear power
Q12748	fossil fuel
Q12802	nuclear weapon
Q14745	furniture
Q15328	camera
Q16338	personal computer
Q17422	same-sex marriage
Q17514	graffiti
Q17516	street art
Q17517	mobile phone
Q17884	LGBTQ
Q18097	Korea
Q18334	particle physics
Q20502	house music
Q20899	podcast
Q21198	computer science
Q22645	smartphone
Q22656	petroleum
Q22676	shoe
Q22687	bank
Q22692	freedom of speech
Q22857	climbing
Q22890	Ireland
Q23397	lake
Q23498	archaeology
Q23548	National Aeronautics and Space Administration
Q24925	science fiction
Q25261	meteorology
Q25956	space station
Q26384	do it yourself
Q26643	commerce
Q27381	North Africa
Q27939	singing
Q29137	cybercrime
Q29468	Republican Party
Q29552	Democratic Party
Q29583	fashion design
Q30022	café
Q30612	clinical trial
Q30849	blog
Q31987	freestyle swimming
Q32096	Super Bowl
Q32112	boxing
Q33521	applied mathematics
Q33999	actor
Q34006	Hollywood
Q34316	Doctor Who
Q34362	astrology
Q34581	childbirth
Q35535	police
Q35865	inflation
Q35986	aesthetics
Q36649	visual arts
Q36963	hunting
Q37038	advertising
Q37073	pop music
Q38108	figure skating
Q38112	forestry
Q38166	modern art
Q38695	cooking
Q38848	heavy metal music
Q38926	news
Q39162	open source
Q39201	pet
Q39286	entomology
Q39680	macroeconomics
Q39760	Gaza Strip
Q39809	marketing
Q40015	solar energy
Q40231	public election
Q40821	surgery
Q40831	comedy
Q40858	natural gas
Q41323	American football
Q41425	ballet
Q41466	ice hockey
Q41710	ethnic group
Q42486	wrestling
Q42998	orchestra
Q43006	tattoo
Q43015	finance
Q43035	electrical engineering
Q43059	drought
Q43183	insurance
Q43302	wind power
Q43450	gymnastics
Q43619	natural environment
Q44497	mining
Q44554	law enforcement
Q45085	fast bowling
Q46169	national park
Q46241	drag racing
Q46255	geophysics
Q46383	sushi
Q46970	airline
Q47146	user interface
Q47566	United States presidential election
Q47728	hobby
Q48196	stem cell
Q48264	gender identity
Q48493	iOS
Q48519	sport management
Q48525	Federal Government of the United States
Q48890	college basketball
Q49394	weapon of mass destruction
Q49451	progressive rock
Q50637	art history
Q52120	glaciology
Q53121	cycling
Q58339	disco
Q58734	pollution
Q59816	racial segregation
Q61065	water sport
Q61509	travel
Q66076	foreign exchange market
Q66221	computer storage media
Q77590	civil engineering
Q80006	computer programming
Q80831	integrated circuit
Q80993	software engineering
Q82604	design
Q83042	neurology
Q83267	crime
Q83270	hard rock
Q83364	vegetarianism
Q83371	seismology
Q83440	country music
Q93204	documentary film
Q101017	distillation
Q102904	volcanology
Q108429	archery
Q113453	gender equality
Q114466	mixed martial arts
Q119380	gentrification
Q123028	pediatrics
Q124100	bodybuilding
Q124946	gardening
Q125928	climate change
Q126793	retail
Q128570	bioinformatics
Q128581	breast cancer
Q129238	startup company
Q130949	skiing
Q131123	air pollution
Q131207	cosmetics
Q131257	intellectual property
Q131265	popular culture
Q131272	soul
Q131288	immigration
Q131327	homelessness
Q131436	board game
Q131723	Bitcoin
Q131728	Total Nonstop Action Wrestling
Q132311	fantasy
Q132580	recycling
Q133823	migraine
Q134147	pop art
Q136822	higher education
Q140247	unicameralism
Q141022	eclipse
Q141090	encryption
Q142714	card game
Q143487	Arab world
Q152518	Burning Man
Q154430	anxiety
Q156537	domestic violence
Q157443	comedy film
Q159810	economy
Q159992	surfing
Q160738	role-playing game
Q162555	oncology
Q164444	funk
Q165647	organic agriculture
Q165838	limnology
Q165950	espionage
Q168796	spirituality
Q169207	discrimination
Q170063	wedding dress
Q170519	virtual reality
Q170611	techno
Q170978	robotics
Q171038	softball
Q171171	dermatology
Q173799	entertainment
Q174165	innovation
Q174989	file system
Q176494	recession
Q176555	quantum computer
Q177190	sleep disorder
Q177626	human migration
Q177765	biometrics
Q178131	snowboarding
Q178476	monetary policy
Q178790	labor union
Q178803	international trade
Q179073	protectionism
Q179179	interest rate
Q179226	equestrianism
Q179310	computing
Q179415	massage
Q181508	extraterrestrial life
Q182415	reality television
Q182442	plastic surgery
Q182868	weather forecasting
Q182940	dessert
Q183257	psychotherapy
Q183484	graphics processing unit
Q184485	performing arts
Q184793	computer-aided design
Q185029	first-person shooter
Q185142	initial public offering
Q185733	philanthropy
Q185867	film noir
Q185925	graphic design
Q186005	physiotherapy
Q186030	contemporary art
Q187117	lobbying
Q187916	horse racing
Q188504	alternative medicine
Q188506	online banking
Q188728	privacy
Q188784	superhero
Q189004	college
Q189177	3D computer graphics
Q189436	speech recognition
Q189447	risk management
Q189603	public health
Q189900	information security
Q190117	automotive industry
Q190637	web design
Q190656	multiculturalism
Q191600	civil and political rights
Q192280	sex education
Q193078	injury
Q193210	skydiving
Q193692	electric car
Q196342	digital single-lens reflex camera
Q197536	deep learning
Q200092	horror film
Q200435	free trade
Q200539	dress
Q201424	nuclear warfare
Q202833	social media
Q205398	social work
Q206717	planetary system
Q207694	art museum
Q208697	financial market
Q211236	celebrity
Q211485	space technology
Q212434	Olympic sport
Q212930	online shopping
Q213051	non-fiction
Q213156	performance art
Q213205	San Francisco Bay Area
Q213376	winemaking
Q216507	bird migration
Q216685	orthopedics
Q216920	secularism
Q219067	physical exercise
Q219239	recipe
Q219409	venture capital
Q219625	fine art
Q220505	film festival
Q220695	wholesale
Q221635	track cycling
Q223371	stock market index
Q223705	mountain bike
Q229367	3D printing
Q234138	Japanese cuisine
Q235038	technical analysis
Q235065	Broadway theatre
Q235799	cyborg
Q235858	traditional folk music
Q237151	medical ethics
Q241741	wildlife
Q243606	industrial design
Q251212	Internet of Things
Q253414	FIFA
Q253613	personal finance
Q253623	patent
Q254183	augmented reality
Q258307	national security
Q259745	witchcraft
Q274393	bakery
Q274586	sports car
Q276530	American Football Conference
Q283534	recreational fishing
Q300920	esports
Q305918	iOS jailbreaking
Q309252	physical fitness
Q316930	dance music
Q317309	mental health
Q319007	National Football Conference
Q319845	investment bank
Q325421	business-to-business
Q326827	artistic gymnastics
Q327333	government agency
Q328716	motorcycle sport
Q329864	military technology
Q330963	politics of the United States
Q331828	overfishing
Q332154	ageing
Q346799	Lifestyle
Q362854	endurance training
Q371804	sports car racing
Q372765	credit rating
Q380778	organic food
Q437458	elderly care
Q455550	camping
Q459290	independent film
Q459426	animal welfare
Q461696	barbecue
Q473750	world economy
Q475000	stock market
Q477248	pastry
Q483251	death metal
Q483639	cloud computing
Q484847	e-commerce
Q485396	analytics
Q492038	human brain
Q495304	forensic science
Q500050	cross country running
Q507443	pharmaceutical industry
Q520611	mountain biking
Q558685	content marketing
Q581105	consumer electronics
Q582577	economic policy
Q605076	cookbook
Q606060	women's association football
Q607695	property tax
Q608003	motorcycling
Q612825	online dating service
Q620615	mobile app
Q624482	sprinting
Q625568	show business
Q629029	occupational health and safety
Q650241	financial institution
Q651658	freight transport
Q654810	dating
Q656365	employment
Q671224	data center
Q683794	new media
Q684740	real property
Q708562	contempt of court
Q718113	weight loss
Q720398	baking
Q725377	graphic novel
Q732717	law enforcement agency
Q741490	autonomous car
Q746359	music industry
Q747915	NFC West
Q748643	swimming at the Summer Olympics
Q757520	atmospheric sciences
Q768575	lens
Q772298	homeless shelter
Q779935	Tollywood
Q782762	adventure travel
Q815679	supercar
Q830036	shopping
Q837171	financial services
Q840400	evolutionary biology
Q842284	skateboarding
Q843592	automatic transmission
Q846662	game show
Q848436	home automation
Q848507	commercial bank
Q849340	cyberwarfare
Q858330	romance novel
Q858439	presidential election
Q858810	big data
Q859369	comedy drama
Q860626	romantic comedy
Q861974	reducing diet
Q862571	petroleum industry
Q865851	supermodel
Q868217	sports video game
Q868557	music festival
Q878123	racing
Q880371	software industry
Q890794	hydraulic fracturing
Q897825	firefighting
Q898886	fly fishing
Q907703	tobacco industry
Q913709	market research
Q920890	mobile operating system
Q931597	Marvel Universe
Q941594	video game industry
Q961015	women's boxing
Q1043805	mobile web
Q1061635	video game development
Q1064131	day trading
Q1068473	educational technology
Q1070427	internet security
Q1071389	gold mining
Q1071646	world news
Q1076968	digital media
Q1109032	college football
Q1121542	mobile game
Q1130645	open-source software
Q1132127	hip hop culture
Q1134763	corporate finance
Q1140647	fastball
Q1149776	data management
Q1152037	aerobic exercise
Q1154336	rock climbing
Q1163715	Major League Baseball
Q1186952	interactive media
Q1193236	news media
Q1194492	angling
Q1196314	stock
Q1215884	National Football League
Q1265288	horse breeding
Q1301371	computer network
Q1323528	digital marketing
Q1326354	parenting
Q1368380	FM broadcasting
Q1401416	computer animation
Q1415395	film industry
Q1416547	financial plan
Q1425378	weight training
Q1430548	effects of climate change
Q1483757	solar power
Q1501619	water management
Q1526011	political science of religion
Q1594437	nightlife
Q1621599	homebrewing
Q1622659	hockey
Q1640676	traffic engineering
Q1684170	spin bowling
Q1747689	Ancient Rome
Q1758324	stock car racing
Q1773974	preventive medicine
Q1778821	cuisine
Q1865281	whale
Q1920219	social issue
Q1962383	sustainable energy
Q1996993	police brutality
Q2057232	Anthony Pettis
Q2072840	CrossFit
Q2138622	nutrition
Q2141830	boating
Q2144359	environmental issue
Q2151621	energy industry
Q2166448	wine tasting
Q2198549	drug development
Q2200417	cognition
Q2374463	data science
Q2446716	lists of television programs
Q2602563	human nutrition
Q2672163	gender role
Q2715623	Social Network Concepts
Q2717839	list of computer hardware manufacturers
Q2727213	theft
Q2738074	political movement
Q2738570	mobile computing
Q2746959	agrochemical
Q2752427	medical research
Q2798820	security hacker
Q2916762	high-definition video
Q2927074	internet meme
Q3022019	patent application form
Q3087172	developmental disorder
Q3268325	mobile security
Q3298118	suicide prevention
Q3421914	cancer research
Q3510521	computer security
Q3537732	radio reception
Q3701758	list of largest technology companies by revenue
Q3908516	entrepreneurship
Q3919913	Category:American musicians
Q4232928	Native Americans
Q4323994	traffic
Q4394526	international law
Q4573533	amateur boxing
Q4830453	business
Q4845080	wearable technology
Q5057302	sound recording process
Q5146583	college sports
Q5193377	cultural institution
Q5380492	entertainment technology
Q5380748	Entrepreneurial leadership
Q5381254	environmental impact of the energy industry
Q6054678	International football
Q6554101	medical device
Q6641956	list of surgical procedures
Q6710019	list of dance styles
Q6764273	marine architecture
Q6869278	vocational education
Q6967866	Category:Automotive technologies
Q7025944	Category:Television personalities
Q7171565	pet adoption
Q7210356	political organization
Q7247798	product testing
Q7247856	productivity software
Q7600677	computer graphics
Q7643429	superhero comics
Q8031191	women's health
Q8189417	environmental movement
Q10836209	digital currency
Q10858400	political corruption
Q10952243	industrial technology
Q12014035	hiking
Q12880211	mining of coal
Q12969754	electromagnetic radiation
Q13629441	electric vehicle
Q14192164	list of accidents and disasters by death toll
Q15067276	health care industry
Q15078788	broadcasting
Q15281614	Xbox
Q15991269	amateur sports
Q16319025	fintech
Q16874254	Ministry of Social Affairs
Q17163326	motorcycle racing
Q18012472	watchOS
Q20077126	sound recording and reproduction
"""
}
