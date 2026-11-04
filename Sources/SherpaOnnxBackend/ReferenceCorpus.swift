import Foundation

/// The texts, voices and look-alike words the learning tools check an engine against. Synthesised with the Mac's own voices (`say`),
/// so nothing here is recorded speech and nothing is shipped: the audio is made on the machine that needs it.
public enum ReferenceCorpus {
    /// Distinct, natural-sounding English voices. (Careful: `say -v NAME` quietly uses the system's *default* voice — here a Spanish
    /// one — when NAME is not found: listed but not downloaded, an ambiguous short name, or an accented name that reached `say`
    /// decomposed, which Foundation's `Process` does and `MacSpeech.run` does not. So Alex, Victoria, Eddy, Flo, Reed, Sandy and
    /// Shelley would all be the same Spanish-accented clip. An earlier corpus had 17 copies of it.)
    public static let englishVoices = [
        "Daniel", "Samantha", "Karen", "Moira", "Rishi", "Tessa", "Kathy", "Ralph", "Junior", "Tara", "Aman",
    ]
    /// Spanish voices reading an English word: a rough stand-in for a Spanish speaker's accent. "Mónica" here is what the
    /// system's default (Castilian) voice speaks; Paulina is Mexican. Two voices, not a population.
    public static let spanishVoices = ["Paulina", "Mónica"]
    /// Every Spanish voice macOS ships that really is installed (each speaks differently from the system default), Mexican and
    /// Castilian: the voices of `--set spanish`.
    public static let spanishSetVoices = [
        "Paulina", "Mónica",
        "Eddy (Español (México))", "Flo (Español (México))", "Reed (Español (México))", "Sandy (Español (México))",
        "Shelley (Español (México))", "Rocko (Español (México))", "Grandma (Español (México))", "Grandpa (Español (México))",
        "Eddy (Español (España))", "Flo (Español (España))", "Reed (Español (España))", "Sandy (Español (España))",
        "Shelley (Español (España))", "Rocko (Español (España))", "Grandma (Español (España))", "Grandpa (Español (España))",
    ]
    /// "Jarvis" inside Spanish sentences, read by Spanish voices — the nearest thing to a Spanish speaker saying it that the Mac can make.
    public static let spanishPositives = [
        "Jarvis", "Oye Jarvis", "Hola Jarvis", "Jarvis, ¿qué hora es?", "Oye Jarvis, enciende la luz", "Dime Jarvis", "Gracias Jarvis",
        "Jarvis ayúdame", "Hey Jarvis", "Ok Jarvis",
    ]
    /// Spanish words and names that sound a little like it: Javier above all.
    public static let spanishDecoys = [
        "Javier", "Javi", "Xavier", "Jabalí", "Jarabe", "Jarra", "Carvajal", "Chávez", "Harvey", "Garbanzos", "Cervantes", "Servicio",
        "Nervios", "Jarrón", "Marvin", "Gervasio",
    ]
    public static let spanishParagraphs = [
        "Esta mañana me levanté temprano para ir al mercado. Compré tomates, cebollas y un poco de pan fresco, y de vuelta a casa preparé un café bien cargado. Después estuve un rato leyendo el periódico en la terraza, mientras el sol empezaba a calentar las calles del barrio.",
        "El fin de semana vamos a viajar a la costa con unos amigos. Hemos reservado un apartamento cerca de la playa y pensamos pasar los dos días paseando, comiendo pescado y descansando. Si el tiempo acompaña, quizá alquilemos unas bicicletas para recorrer el paseo marítimo.",
        "Para hacer la tortilla de patatas necesitas seis huevos, cuatro patatas medianas y una cebolla. Primero fríes las patatas a fuego lento, luego las mezclas con el huevo batido y lo cuajas en la sartén. Dale la vuelta con un plato y déjala dorarse por el otro lado.",
        "La reunión de mañana empezará a las diez en la sala grande del segundo piso. Por favor, traed vuestros informes impresos y no olvidéis revisar los números del último trimestre. Si alguien no puede asistir, que avise con tiempo para reorganizar el orden del día.",
        "Mi abuela solía contarme historias de cuando era niña y vivía en un pueblo pequeño de la montaña. Decía que en invierno la nieve cubría los caminos durante semanas y que los vecinos se ayudaban unos a otros llevando leña y comida a las casas más alejadas.",
        "Según el pronóstico, esta tarde habrá nubes y algo de lluvia en el norte, mientras que en el sur seguirá haciendo calor. Las temperaturas bajarán un poco durante la noche, y mañana por la mañana podría haber niebla en las zonas altas, así que conviene conducir con precaución.",
        "Estoy buscando un libro para regalarle a mi hermano por su cumpleaños. Le gustan las novelas históricas y los libros de viajes, pero ya tiene casi todos los que he visto en la librería. Quizá le compre una entrada para un concierto, que seguro le hace más ilusión.",
        "Cuando llegamos a la estación, el tren ya había salido y tuvimos que esperar casi una hora al siguiente. Aprovechamos para tomar algo en la cafetería, charlar un rato y comprar algunos periódicos para el viaje, que iba a durar más de tres horas.",
        "Los investigadores han descubierto que caminar media hora al día mejora el estado de ánimo y ayuda a dormir mejor. En el estudio participaron más de mil personas durante dos años, y los resultados fueron especialmente buenos entre quienes salían a pasear al aire libre.",
        "Ayer por la noche fuimos al cine a ver la película de la que todo el mundo habla. Al principio me pareció un poco lenta, pero la segunda mitad es muy emocionante y el final sorprende. Al salir estuvimos comentándola en la puerta durante casi veinte minutos.",
    ]
    /// Spanish speech full of the names above (Javier, Xavier, jarabe, Chávez, Harvey…): the Spanish counterpart of the look-alike sentences.
    public static let spanishLookalikeParagraphs = [
        "Ayer llamé a Javier para quedar el sábado, pero me dijo que estaba trabajando. Javi suele tener turnos raros en el hospital, así que casi nunca sabemos cuándo está libre. Le dije que cuando termine me avise y buscamos un sitio para cenar los tres.",
        "En el mercado compré una jarra de cerámica y un frasco de jarabe de arce para las tostadas. La vendedora, que se llama Marta, me explicó que el jarabe viene de Canadá y que no hay que guardarlo en la nevera hasta que se abre.",
        "El presidente Chávez dio un discurso muy largo en la plaza principal, según cuentan los periódicos de aquella época. Mi profesor de historia nos explicó que Hugo Chávez gobernó durante muchos años y que su figura sigue dividiendo opiniones en todo el continente.",
        "Xavier y yo estudiamos juntos en la universidad. Él se fue a vivir a Barcelona y yo me quedé aquí, pero seguimos hablando cada semana por teléfono. El mes pasado vino a visitarme con su mujer y paseamos por el casco antiguo toda la tarde.",
        "Mi vecino Harvey es inglés y lleva veinte años viviendo en España. Habla un español perfecto, aunque a veces mezcla palabras de los dos idiomas. Ayer me contó que el servicio de correos le había perdido un paquete y que tardaron tres semanas en encontrarlo.",
        "El señor Carvajal nos enseñó el huerto de su casa. Tiene tomates, pimientos y unas calabazas enormes. Dice que el secreto es regar temprano y no dejar que la tierra se seque, y que el abono de los caballos de su cuñado funciona mejor que cualquier otro.",
    ]
    public static let positives = [
        "Jarvis", "Jarvis.", "Hey Jarvis", "Jarvis, what time is it?", "Okay Jarvis, turn on the lights.",
        "Please ask Jarvis to open the door.", "Jarvis! Wake up!",
    ]
    /// A second set that no setting was tuned on (`--heldout`): other sentences, other look-alike names (mostly rhymes with Jarvis).
    public static let heldOutPositives = [
        "Jarvis, remind me to call my mother.", "Good evening, Jarvis.", "Jarvis, what is the weather like?",
        "Hey Jarvis, are you listening?", "Thank you Jarvis, that is all.", "I said Jarvis.", "Jarvis, stop.",
    ]
    public static let heldOutDecoys = [
        "Harris", "Davis", "Mavis", "Elvis", "Curtis", "Gervase", "Jarvie", "Marcus", "Alice", "Services", "Carvers",
        "Harvests", "Travers", "Nervous system", "Dervish dance",
    ]
    /// "Jarvis" with another word right in front of it (`--set continuous`), as it is really said: "hey Jarvis", "okay Jarvis…".
    public static let continuousPositives = [
        "Hey Jarvis", "Okay Jarvis", "OK Jarvis", "Hi Jarvis", "Hello Jarvis", "Yo Jarvis", "Thanks Jarvis", "Excuse me Jarvis",
        "Hey Jarvis, what time is it", "Okay Jarvis turn on the lights", "So Jarvis", "And Jarvis", "Now Jarvis",
    ]
    public static let decoys = [
        "Travis", "Harvest", "Service", "Jarvik", "Gervais", "Harvey", "Marvin", "Carbs", "Charles", "Harness", "Jar",
        "Larvae", "Garbage", "Nervous", "Survive", "Purpose", "Curfew", "Alexa", "Hey Siri", "Of course", "Jarrett",
        "Chavez", "Dervish", "Harvard", "Marvelous", "Starvation",
    ]
    /// Ordinary speech with nothing in it that sounds like the word.
    public static let paragraphs = [
        "The committee met on Tuesday morning to review the proposal for the new library. Several members raised concerns about the budget, while others argued that the project would bring lasting benefits to the neighbourhood. After two hours of discussion, they agreed to postpone the vote until the architect could provide a more detailed estimate of the costs involved.",
        "When I was young, my grandfather used to take me fishing on the lake every summer. We would wake before sunrise, pack sandwiches and a thermos of coffee, and row out to the quiet bay where the water was always calm. He never said much, but I learned more from those silent mornings than from any classroom.",
        "The weather forecast for the weekend looks mixed. Expect clouds and light rain on Saturday, with temperatures around fifteen degrees. On Sunday the skies should clear in the afternoon, although a cold wind from the north may make it feel considerably cooler than the numbers suggest, so dress accordingly.",
        "To make the sauce, heat two tablespoons of olive oil in a large pan and add the chopped onions. Cook them slowly until they are soft and golden, then stir in the garlic, the tomatoes and a pinch of salt. Let everything simmer for about twenty minutes, stirring from time to time, until the sauce thickens.",
        "Researchers have found that regular exercise can improve memory and concentration, even in people who start late in life. In one study, volunteers who walked briskly for forty minutes three times a week performed better on tests of attention than a similar group who only stretched. The effect appeared after just six months.",
        "I think we should meet at the station around seven, have dinner somewhere near the river, and then decide whether to go to the concert or just walk around the old town. My sister said she might join us if her train is on time, and she wants to bring her friend from work, whom none of us have met yet.",
        "The museum reopens next month after a long renovation. Visitors will find a new entrance, a larger café on the first floor, and several galleries that have been completely redesigned. The most popular exhibit, a collection of medieval maps, will return in a special room with better lighting and climate control.",
        "She opened the window and looked down at the empty street. A few lights were still on in the houses across the road, and somewhere in the distance a dog was barking. It was almost midnight, and she realised that she had been sitting at the desk for nearly six hours without moving.",
        "To get to the airport, take the number nine bus from the central station and get off at the last stop. The ride lasts about thirty-five minutes. Make sure you have your passport ready, because the security queue can be long in the summer.",
        "I was telling Maria about the documentary on deep sea creatures that we saw yesterday. Some of the animals produce their own light, and others survive without any food for months. She said she would watch it tonight with her brother.",
        "The committee will meet on the fifth of March to discuss the budget for next year. Members are asked to read the attached report in advance, in particular the sections on transport and housing, and to send any questions to the secretary by the end of the week.",
        "After the concert we walked along the river until the lights of the bridge came on. It was cold, but nobody wanted to go home yet. Somebody suggested getting a hot chocolate, and we ended up in a tiny café that was about to close.",
        "The new phone has a much better camera than the previous model, and the battery lasts almost two days with normal use. The only complaint reviewers have is the price, which is quite high, and the lack of a headphone socket for people who still use wired earphones.",
        "When the alarm went off at six, the whole house was still dark. I made coffee, packed a sandwich and checked the weather once more before leaving. The roads were empty, and by seven I was already crossing the mountain pass with the radio on low.",
        "Turn left at the traffic light, then continue straight for two blocks until you see a pharmacy on the corner. The entrance to the building is just behind it, through the green door. Ring the second bell and I will come down to let you in.",
        "Our teacher gave us a surprising assignment this week: instead of writing an essay we have to interview an older relative about their childhood. I chose my grandmother, who grew up in a small village with no electricity and walked three kilometres to school.",
    ]
    /// Sentences that contain names and words that *sound like* the word (Travis, Gervais, Charles, garbage…): the
    /// hardest ordinary speech there is, so it is reported on its own.
    public static let lookalikeParagraphs = [
        "Last Tuesday my neighbour Travis told me the service at the new restaurant was terrible. We waited forty minutes for the starters, and when the food finally arrived it was cold. I will probably not go back, although the desserts looked wonderful.",
        "The harvest this year was better than anyone expected. After a dry spring the rains arrived in June, and by September the farmers were bringing in more grain than they had seen in a decade. Prices at the market are expected to fall as a result.",
        "Please remember to take out the garbage before you leave. The recycling goes in the blue bin, and the glass has to be rinsed first. If you have time, could you also water the plants on the balcony? They have not had any water since Friday.",
        "Doctor Harvey explained that the procedure was routine and that most patients go home the same afternoon. He asked me to avoid heavy meals the night before and to bring someone along who could drive me back. I was nervous, but his calm voice helped a lot.",
        "My cousin Charles is moving to Chicago next month for a new job at a software company. He has already found an apartment near the lake, and he says the commute will be shorter than the one he has now. We are planning a farewell dinner on Saturday.",
        "The marvelous thing about this old library is that nobody seems to hurry. People sit for hours with a single book, and the librarian, Mister Gervais, knows every regular by name. On rainy afternoons the reading room smells of coffee and wet umbrellas.",
        "Carbs are not the enemy, my trainer says, as long as you pick the right ones. Oats, beans and whole grain bread keep you full for hours, while sugary snacks leave you hungry again after twenty minutes. He also recommends sleeping at least seven hours.",
        "Starvation was never a real danger on the island, the historian wrote, because the sea provided fish in every season. What the settlers lacked were tools and timber, and for the first winters they depended entirely on the supply ships that arrived each spring.",
    ]
}
