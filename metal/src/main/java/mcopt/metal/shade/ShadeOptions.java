/*
 * Copyright 2026 mcopt-shade contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package mcopt.metal.shade;

import static mcopt.metal.shade.ShadeOption.choice;
import static mcopt.metal.shade.ShadeOption.custom;
import static mcopt.metal.shade.ShadeOption.num;
import static mcopt.metal.shade.ShadeOption.pct;
import static mcopt.metal.shade.ShadeOption.pctInt;
import static mcopt.metal.shade.ShadeOption.pctOf;
import static mcopt.metal.shade.ShadeOption.tier;
import static mcopt.metal.shade.ShadeOption.toggle;

import java.util.ArrayList;
import java.util.List;

/**
 * (1.1, Gael: "deja la configuración totalmente abierta, como los otros shaderpacks") Every setting of the shader settings
 * screen, by page: the look (light, shadows, colour, atmosphere, god rays, clouds, night sky, water, weather, Nether and End) and
 * performance. Each is a property its module reads live (Live, ShadeSettings) unless marked restart(). The keys and what they do
 * are in work/notes/v11-2026-10-13/SPEC.md; the defaults here must be the modules' own (preset-dependent ones by tier()).
 */
public final class ShadeOptions {
	/** A page: its title and its items, in order (a String[] {es, en} is a section header, a ShadeOption a setting). */
	public record Page(String es, String en, String tipEs, String tipEn, List<Object> items) {
		public String title() {
			return ShadeLang.t(this.es, this.en);
		}

		public List<ShadeOption> options() {
			List<ShadeOption> out = new ArrayList<>();
			for (Object o : this.items) if (o instanceof ShadeOption s) out.add(s);
			return out;
		}
	}

	private static final String U = "mcopt.shade.user.";
	private static final String[] ON = {"Sí", "On"};

	/** The quality preset (restart) and the style: on the main page. */
	public static final ShadeOption PRESET = choice("mcopt.shade.preset", "Preset", "Preset",
		"Cuánto trabaja la GPU: resolución interna, sombras, nubes, reflejos y rayos de sol.",
		"How hard the GPU works: internal resolution, shadows, clouds, reflections and god rays.",
		new String[] {"performance", "balanced", "quality", "ultra"}, new String[] {"Rendimiento", "Balanceado", "Calidad", "Ultra"},
		new String[] {"Performance", "Balanced", "Quality", "Ultra"}, () -> Shade.TIER).restart();
	public static final ShadeOption STYLE = choice("mcopt.shade.look", "Estilo", "Style",
		"Épico: colores intensos. Cuento: más suave y cálido. Natural: más realista.", "Epic: rich colours. Storybook: softer and warmer. Natural: more realistic.",
		new String[] {"epic", "storybook", "natural"}, new String[] {"Épico", "Cuento", "Natural"}, new String[] {"Epic", "Storybook", "Natural"}, () -> 0);

	public static final List<Page> PAGES = new ArrayList<>();

	private static Page page(String es, String en, String tipEs, String tipEn, Object... items) {
		Page p = new Page(es, en, tipEs, tipEn, new ArrayList<>(List.of(items)));
		PAGES.add(p);
		return p;
	}

	private static String[] h(String es, String en) {
		return new String[] {es, en};
	}

	static {
		page("Iluminación", "Lighting", "Sol, luna, cielo, antorchas, cuevas y luces en la mano.", "Sun, moon, sky, torches, caves and held lights.",
			h("Modo", "Mode"),
			choice(ShadeLighting.KEY, "Modo de iluminación", "Lighting mode",
				"Actual: la iluminación original. Natural: más contraste entre exteriores e interiores y adaptación más gradual. Cambia al instante; requiere iluminación mejorada.",
				"Current keeps the original lighting. Natural adds daylight/interior contrast and gentler dark adaptation. Switch live; requires Improved lighting. Independent of Style.",
				new String[] {"current", "natural"}, new String[] {"Actual", "Natural"}, new String[] {"Current", "Natural"}, () -> 0),
			pctOf(ShadeLighting.STRENGTH, "Intensidad natural", "Natural strength",
				"En modo Natural: 0% = Actual, 50% = Natural original, 100% = más contraste entre exteriores e interiores. Se aplica al instante.",
				"In Natural mode: 0% = Current, 50% = the original Natural look, 100% = stronger daylight/interior contrast. Adjust live.",
				0, 100, () -> 50, 2f),
			h("Sol y cielo", "Sun and sky"),
			pct(U + "sunLight", "Luz del sol", "Sunlight", "Qué tan fuerte ilumina el sol.", "How strong the sunlight is.", 20, 300, 100),
			pct(U + "moonLight", "Luz de la luna", "Moonlight", "Qué tan fuerte ilumina la luna.", "How strong the moonlight is.", 20, 400, 100),
			pct(U + "skyLight", "Luz del cielo", "Skylight", "La luz azul del cielo que llena las sombras.", "The sky's blue light that fills the shadows.", 20, 300, 100),
			pct(U + "bounce", "Luz rebotada", "Bounce light", "La luz cálida que rebota del suelo y las paredes hacia las sombras.",
				"The warm light the sunlit ground and walls bounce into the shadows.", 0, 400, 100),
			pct(U + "sunColor", "Color del sol", "Sunlight colour", "Qué tan intenso es el color de la luz (dorado al atardecer).",
				"How deep the light's colour is (gold at sunset).", 50, 160, 100),
			num(U + "nightEv", "Brillo de noche", "Night brightness", "Más o menos luz de noche, en pasos de exposición.", "More or less light at night, in exposure steps.",
				-20, 30, () -> 0, 10, " EV"),
			toggle("mcopt.shade.light2", "Iluminación mejorada", "Improved lighting", "Luz rebotada cálida, antorchas más suaves y cuevas frías. No = la luz de la versión 1.0 temprana.",
				"Warm bounce light, softer torches and cool caves. Off = the early lighting model.", true),
			h("Antorchas y cuevas", "Torches and caves"),
			pct(U + "torch", "Luz de antorchas", "Torch light", "Qué tan fuerte iluminan antorchas, linternas, lava y fuego.",
				"How strong torches, lanterns, lava and fire light things.", 0, 300, 100),
			custom(U + "torchKelvin", "Tono antorchas", "Torch colour", "Natural: el naranja de siempre. Menos grados: más rojo. Más grados: más blanco.",
				"Natural: the usual orange. Fewer kelvin: redder. More kelvin: whiter.", 0, 47, () -> 0, p -> p == 0 ? "0" : Integer.toString(1700 + p * 100),
				v -> {
					float k = ShadeOption.parse(v, Float.NaN);
					return Float.isNaN(k) ? Integer.MIN_VALUE : k < 1000f ? 0 : Math.round((k - 1700f) / 100f);
				}, p -> p == 0 ? ShadeLang.t("Natural", "Natural") : (1700 + p * 100) + " K"),
			pct(U + "caveLight", "Luz en cuevas", "Cave light", "La luz que tiene un lugar sin cielo ni antorchas.",
				"The light a place gets with no sky and no torches.", 0, 600, 100),
			pctOf("mcopt.shade.caveFog", "Aire de cuevas", "Cave air glow", "Qué tanto brilla el aire dentro de las cuevas.", "How much the air inside caves glows.",
				0, 300, () -> 50, 0.01f),
			toggle("mcopt.shade.caveAir", "Aire de cueva oscuro", "Dark cave air", "Dentro de las cuevas, la neblina no brilla con la luz del cielo.",
				"Inside caves the haze doesn't glow with the sky's light.", true),
			h("Materiales", "Materials"),
			pct(U + "leafLight", "Luz en hojas", "Leaf light", "Cuánta luz pasa por las hojas y plantas a contraluz.",
				"How much light shines through leaves and plants against the sun.", 0, 300, 100),
			pct(U + "emissive", "Bloques de luz", "Glowing blocks", "Cuánto brillan las llamas, la glowstone y la lava.",
				"How much flames, glowstone and lava glow.", 0, 300, 100),
			h("Luz en la mano", "Held light"),
			pctOf("mcopt.shade.dynLights.strength", "Intensidad", "Strength", "Luz de las antorchas y linternas que llevas o que llevan los mobs.",
				"Light from torches and lanterns you or mobs hold.", 0, 400, () -> 100, 0.01f),
			toggle("mcopt.shade.dynLights.hand", "Luz de tu mano", "Hand light", "Lo que tienes en la mano ilumina alrededor.",
				"What you hold lights up the area.", true),
			toggle("mcopt.shade.dynLights.others", "Luz de mobs", "Mob and item light", "Mobs, objetos tirados y flechas en llamas también iluminan.",
				"Mobs, dropped items and burning arrows light up too.", true),
			toggle("mcopt.shade.dynLights.flicker", "Parpadeo del fuego", "Fire flicker", "La luz del fuego parpadea un poco.", "Fire light flickers a little.", true),
			toggle("mcopt.shade.dynLights.playerLight", "Luz desde los ojos", "Light from the eyes", "Tu luz sale desde la cámara, como en Photon y Complementary.",
				"Your light comes from the camera, like in Photon and Complementary.", true),
			toggle("mcopt.shade.dynLights.soft", "Luz en esquinas", "Light around corners", "La luz llega un poco detrás de las esquinas.",
				"Light reaches a little around corners.", true),
			toggle("mcopt.shade.dynLights.playerShadows", "Sombras de tu luz", "Own light shadows", "Tu propia luz proyecta sombras.", "Your own light casts shadows.", false),
			num("mcopt.shade.dynLights.range", "Alcance", "Range", "Hasta qué distancia se buscan luces en movimiento.", "How far away moving lights are picked up.",
				8, 60, () -> 48, 1, ShadeOption.BLOCKS));

		page("Sombras", "Shadows", "Sombras del sol, de mobs, de nubes y de vidrios de color.", "Sun, mob, cloud and stained-glass shadows.",
			toggle("mcopt.shade.pcss", "Sombras suaves", "Soft shadows", "Las sombras se vuelven más difusas lejos de lo que las proyecta.",
				"Shadows get softer farther from what casts them.", true),
			pct(U + "shadowSoftness", "Suavidad", "Softness", "Qué tan difusos son los bordes de las sombras.", "How blurry shadow edges are.", 25, 400, 100),
			num("mcopt.shade.shadowDist", "Distancia", "Distance", "Hasta dónde hay sombras. Más lejos = un poco menos de detalle.",
				"How far shadows reach. Farther = a little less detail.", 64, 512, () -> 128, 1, ShadeOption.BLOCKS),
			choice("mcopt.shade.shadowRes", "Resolución", "Resolution", "Detalle de las sombras. Más alto = más nítidas y más lentas.",
				"Shadow detail. Higher = sharper and slower.", new String[] {"1024", "2048", "3072", "4096"}, new String[] {"1024", "2048", "3072", "4096"},
				new String[] {"1024", "2048", "3072", "4096"}, tier(1, 1, 1, 2)).restart(),
			toggle("mcopt.shade.entityShadows.pause", "Sombras de mobs", "Mob shadows", "Mobs, objetos y cofres proyectan sombras del sol.",
				"Mobs, items and chests cast sun shadows.", true, true),
			toggle("mcopt.shade.colorShadows", "Sombras de colores", "Coloured shadows", "La luz que pasa por vidrio de color o agua toma su color.",
				"Light through stained glass or water takes its colour.", true),
			toggle("mcopt.shade.clouds.shadows", "Sombras de nubes", "Cloud shadows", "Las nubes oscurecen el suelo y el agua.", "Clouds darken the ground and water.", true),
			pctOf("mcopt.shade.clouds.shadowStrength", "Intensidad (nubes)", "Strength (clouds)", "Qué tan oscuras son las sombras de las nubes.",
				"How dark cloud shadows are.", 0, 100, () -> 80, 0.01f),
			num("mcopt.shade.waterShadowSoft", "Sombras en el agua", "Water shadow blur", "Qué tan difusas son las sombras sobre el agua.",
				"How blurry shadows on water are.", 0, 80, () -> 20, 10, ""),
			toggle("mcopt.shade.endShadows", "Sombras en el End", "Shadows in the End", "La luz del End proyecta sombras.", "The End's light casts shadows.", true));

		page("Color y cámara", "Colour and camera", "Brillo, colores, exposición, resplandor y nitidez.", "Brightness, colours, exposure, bloom and sharpness.",
			h("Color", "Colour"),
			num("mcopt.shade.ev", "Brillo", "Brightness", "Exposición de la imagen (0 = como viene).", "Exposure of the image (0 = default).", -20, 20, () -> 0, 10, " EV"),
			pctInt(U + "saturation", "Saturación", "Saturation", "Intensidad de los colores.", "How colourful the image is.", 0, 150, 100),
			pct(U + "contrast", "Contraste", "Contrast", "Diferencia entre lo claro y lo oscuro.", "Difference between light and dark.", 70, 140, 100),
			pct(U + "vibrance", "Vibrancia", "Vibrance", "Sube el color de lo que tiene poco color, sin exagerar lo demás.",
				"Boosts dull colours without overdoing the rest.", 0, 400, 100),
			custom(U + "temperature", "Temperatura", "Temperature", "Imagen más cálida (naranja) o más fría (azul).", "A warmer (orange) or cooler (blue) image.",
				-60, 60, () -> 0, Integer::toString, v -> ShadeOption.roundOr(ShadeOption.parse(v, Float.NaN)),
				p -> p == 0 ? "0" : p > 0 ? ShadeLang.t("cálida +", "warm +") + p : ShadeLang.t("fría ", "cool ") + p),
			pct(U + "purkinje", "Tono azul de noche", "Night blue tint", "De noche lo oscuro se ve un poco azul, como lo ve el ojo.",
				"At night dark areas turn a little blue, as the eye sees them.", 0, 200, 100),
			h("Exposición", "Exposure"),
			choice("mcopt.shade.exposure", "Exposición", "Exposure", "Automática: el ojo se adapta a la luz, como en una cámara. Fija: no cambia.",
				"Automatic: the eye adapts to the light, like a camera. Fixed: it doesn't change.", new String[] {"auto", "fixed"},
				new String[] {"Automática", "Fija"}, new String[] {"Automatic", "Fixed"}, () -> 0),
			pct(U + "autoExposure", "Adaptación", "Eye adaptation", "Cuánto aclara las cuevas y oscurece lo brillante.",
				"How much caves get brighter and bright scenes darker.", 0, 200, 100),
			pct(U + "exposureSpeed", "Rapidez del ojo", "Adaptation speed", "Qué tan rápido se adapta el ojo.", "How fast the eye adapts.", 20, 500, 100),
			h("Efectos", "Effects"),
			num("mcopt.shade.beaconBrightness", "Brillo del haz del faro", "Beacon beam brightness", "Intensidad del haz; 1x restaura el brillo anterior.",
				"Beam intensity before bloom and tone mapping; 1x restores the original brightness.", 1, 8, () -> 1, 1, "x"),
			pctInt(U + "bloom", "Resplandor", "Bloom", "El brillo que se esparce alrededor del sol, las antorchas y la lava.", "The glow around the sun, torches and lava.",
				0, 200, 100),
			pct(U + "vignette", "Viñeta", "Vignette", "Bordes de la imagen un poco más oscuros.", "Slightly darker image corners.", 0, 400, 100),
			pctOf("mcopt.shade.sharpen", "Nitidez", "Sharpening", "Afila la imagen después del antialiasing.", "Sharpens the image after anti-aliasing.", 0, 100,
				() -> 30, 0.01f),
			choice("mcopt.shade.taaMode", "Antialiasing", "Anti-aliasing", "Estable: menos parpadeo. Rápido: menos estela al moverse.",
				"Stable: less flicker. Responsive: less ghosting in motion.", new String[] {"stable", "responsive"}, new String[] {"Estable", "Rápido"},
				new String[] {"Stable", "Responsive"}, tier(1, 0, 0, 0)),
			h("Pantalla HDR", "HDR display"),
			choice("mcopt.shade.xdr", "Salida HDR", "HDR output", "Activa la salida HDR en pantallas compatibles. Requiere reiniciar.",
				"Enable HDR output on supported displays. Changing this requires a restart.", new String[] {"auto", "on", "off"},
				new String[] {"Automático", "Sí", "No"}, new String[] {"Automatic", "On", "Off"}, () -> 0).restart(),
			choice("mcopt.shade.hdrMode", "Modo HDR", "HDR mode", "Escena completa: mapea toda la imagen al rango HDR.",
				"Full scene maps all world lighting to HDR. Pause/inventory screens use SDR.", new String[] {"highlights", "scene"},
				new String[] {"Brillos", "Escena completa"}, new String[] {"Highlights", "Full scene"}, () -> 0),
			pctOf("mcopt.shade.hdrSceneBrightness", "Brillo de la escena HDR", "HDR scene brightness", "Exposición de la escena completa HDR.",
				"Scene exposure in Full scene mode; does not change UI brightness.", 50, 200, () -> 100, 0.01f),
			pctOf("mcopt.shade.hdrUiBrightness", "Brillo de interfaz HDR", "HDR UI brightness", "Brillo de interfaz y mano en HDR.",
				"HUD and hand brightness in Full scene mode.", 25, 200, () -> 100, 0.01f),
			num("mcopt.shade.xdrPeak", "Brillo máximo HDR", "HDR peak", "Hasta cuántas veces el blanco pueden brillar las luces.", "How many times brighter than white lights may get.",
				1, 16, () -> 4, 1, "x"));

		page("Atmósfera", "Atmosphere", "Neblinas, niebla, lluvia y colores del atardecer.", "Haze, mist, fog, rain and sunset colours.",
			pctInt(U + "haze", "Neblina del aire", "Air haze", "La neblina azulada del aire.", "The bluish haze in the air.", 0, 200, 100),
			pct(U + "mist", "Neblina del suelo", "Ground mist", "La neblina baja sobre el suelo y el agua.", "The low mist over the ground and water.", 0, 300, 100),
			pct(U + "morningMist", "Neblina matinal", "Dawn mist", "La neblina extra de la mañana.", "The extra mist in the morning.", 0, 300, 100),
			pct(U + "distanceHaze", "Neblina a lo lejos", "Distance haze", "Qué tanto se pierde el paisaje lejano en el aire.", "How much far land fades into the air.", 0, 400, 100),
			pct(U + "rainFog", "Niebla con lluvia", "Rain fog", "Cuánta niebla trae la lluvia.", "How much fog the rain brings.", 0, 300, 100),
			custom(U + "borderFog", "Niebla del borde", "Edge fog start", "Dónde empieza la niebla al final de la distancia de render.",
				"Where the fog at the end of the render distance starts.", 30, 97, () -> 78, p -> ShadeOption.fmt(p / 100f),
				v -> ShadeOption.roundOr(ShadeOption.parse(v, Float.NaN) * 100f), p -> p + "%"),
			pct(U + "sunset", "Atardecer", "Sunset colours", "El dorado y el rosa del cielo al atardecer.", "The sky's gold and rose at sunset.", 0, 200, 100),
			pct(U + "eveningGlow", "Brillo del ocaso", "Evening glow", "El brillo naranja del aire alrededor del sol bajo.", "The orange glow of the air around the low sun.",
				0, 300, 100),
			toggle("mcopt.shade.skyRose", "Cielo rosado", "Rose sky", "Al atardecer, la parte alta del cielo se vuelve rosa.", "At sunset the upper sky turns rose.", true),
			toggle("mcopt.shade.sunsetArt", "Ocaso direccional", "Directional sunset", "Dorado hacia el sol, rosa del otro lado.",
				"Gold toward the sun, rose on the other side.", true),
			toggle("mcopt.shade.haze", "Neblina", "Haze", "Toda la neblina: del aire, del suelo y del borde.", "All the haze: air, ground and edge.", true));

		page("Rayos de sol", "God rays", "Los rayos de luz entre los árboles, las nubes y bajo el agua.", "Light shafts through trees, clouds and under water.",
			pctInt(U + "godrays", "Intensidad", "Strength", "Todos los rayos de luz. 0 = apagados (más FPS).", "All the light shafts. 0 = off (more FPS).", 0, 200, 100),
			pctOf("mcopt.shade.vl.airForest", "Aire del bosque", "Forest air", "La neblina del bosque donde se ven los rayos.", "The forest's haze where the shafts show.",
				0, 250, () -> 100, 0.017f),
			pctOf("mcopt.shade.vl.airGolden", "Más al atardecer", "More at golden hour", "Cuánto más se ven al amanecer y al atardecer.", "How much stronger they get at dawn and dusk.",
				0, 300, () -> 100, 1f),
			num("mcopt.shade.vl.sunsetRays", "Rayos en el cielo", "Rays in the sky", "Las franjas de sombra de las nubes en el cielo del atardecer.",
				"The clouds' shadow streaks across the sunset sky.", 0, 40, () -> 20, 10, "x"),
			pct("mcopt.shade.vl.crepGain", "Rayos hacia el sol", "Rays toward the sun", "Los rayos que salen del sol detrás de árboles y montañas.",
				"The rays fanning out of the sun behind trees and hills.", 0, 300, 100),
			pct(U + "underwaterRays", "Bajo el agua", "Under water", "Los rayos de luz bajo el agua.", "The light shafts under water.", 0, 200, 100),
			h("Calidad", "Quality"),
			pctOf("mcopt.shade.vl.scaleLive", "Resolución", "Resolution", "Resolución de los rayos. Más alta = más nítidos y más lentos.",
				"Resolution of the rays. Higher = sharper and slower.", 20, 100, tier(25, 33, 50, 50), 0.01f),
			num("mcopt.shade.vl.stepsLive", "Pasos", "Steps", "Muestras por rayo. Más = menos ruido y más lento.", "Samples per ray. More = less noise and slower.",
				4, 48, tier(10, 12, 16, 24), 1, ""));

		page("Nubes", "Clouds", "Tipo, cantidad, forma, altura, viento y calidad de las nubes.", "Cloud type, amount, shape, height, wind and quality.",
			choice("mcopt.shade.clouds.mode", "Nubes", "Clouds",
				"Volumétricas: nubes realistas. Cuadradas: las nubes de Minecraft con volumen, luz y sombras. Minecraft: las normales del juego.",
				"Volumetric: realistic clouds. Blocky: Minecraft's clouds with volume, light and shadows. Minecraft: the game's normal clouds.",
				new String[] {"volumetric", "blocky", "vanilla", "off"}, new String[] {"Volumétricas", "Cuadradas", "Minecraft", "No"},
				new String[] {"Volumetric", "Blocky", "Minecraft", "Off"}, ShadeSettings::defaultCloudMode),
			custom(U + "cloudCoverage", "Cantidad", "Amount", "Más o menos nubes que el clima del día.", "More or fewer clouds than the day's weather.", -50, 50, () -> 0,
				p -> ShadeOption.fmt(p / 100f), v -> ShadeOption.roundOr(ShadeOption.parse(v, Float.NaN) * 100f),
				p -> p == 0 ? ShadeLang.t("Del clima", "Weather") : (p > 0 ? "+" : "") + p),
			custom(U + "cloudType", "Forma", "Shape", "Planas o altas como torres. Del clima: cambia cada día.", "Flat or towering. Weather: changes every day.", -1, 100,
				() -> -1, p -> p < 0 ? "-1" : ShadeOption.fmt(p / 100f), v -> {
					float t = ShadeOption.parse(v, Float.NaN);
					return Float.isNaN(t) ? Integer.MIN_VALUE : t < 0f ? -1 : Math.round(t * 100f);
				}, p -> p < 0 ? ShadeLang.t("Del clima", "Weather") : p + "%"),
			pct("mcopt.shade.clouds.density", "Densidad", "Density", "Nubes más gruesas y oscuras o más ligeras.", "Thicker, darker clouds or lighter ones.", 30, 300, 100),
			pct("mcopt.shade.clouds.detail", "Detalle", "Detail", "Los rizos finos de los bordes.", "The fine curls on their edges.", 0, 300, 100),
			pct(U + "cloudBrightness", "Brillo", "Brightness", "Qué tan iluminadas se ven.", "How bright they look.", 25, 200, 100),
			pct(U + "cloudOpacity", "Opacidad", "Opacity", "Qué tan transparentes son.", "How see-through they are.", 0, 100, 100),
			custom("mcopt.shade.clouds.base", "Altura", "Height", "Dónde empiezan. Automática: a la altura de las nubes de Minecraft.",
				"Where they start. Automatic: at Minecraft's cloud height.", 0, 60, () -> 0, p -> p == 0 ? "NaN" : Integer.toString(100 + p * 10), v -> {
					float y = ShadeOption.parse(v, Float.NaN);
					return Float.isNaN(y) ? 0 : Math.round((y - 100f) / 10f);
				}, p -> p == 0 ? ShadeLang.t("Automática", "Automatic") : "y " + (100 + p * 10)),
			num("mcopt.shade.clouds.thickness", "Grosor", "Thickness", "Qué tan altas son las nubes volumétricas.", "How tall the volumetric clouds are.", 20, 600, () -> 150, 1,
				ShadeOption.BLOCKS),
			num("mcopt.shade.clouds.blockThickness", "Grosor cuadradas", "Blocky thickness", "Altura de las nubes cuadradas (Minecraft: 4).",
				"Height of the blocky clouds (Minecraft: 4).", 2, 32, () -> 4, 1, ""),
			pct("mcopt.shade.clouds.wind", "Viento", "Wind", "Qué tan rápido se mueven.", "How fast they move.", 0, 400, 100),
			toggle("mcopt.shade.clouds.cirrus", "Cirros", "Cirrus", "Nubes altas y delgadas como plumas.", "High, thin, feathery clouds.", true),
			pct(U + "cirrusAmount", "Cantidad de cirros", "Cirrus amount", "Cuántos cirros hay.", "How many cirrus clouds there are.", 0, 200, 100),
			toggle("mcopt.shade.clouds.dome", "Nubes en reflejos", "Reflected clouds", "El agua refleja también las nubes fuera de la pantalla.",
				"Water also mirrors clouds outside the screen.", true),
			h("Calidad", "Quality"),
			pctOf("mcopt.shade.clouds.scale", "Resolución", "Resolution", "Resolución de las nubes. Más alta = más nítidas y más lentas.",
				"Cloud resolution. Higher = sharper and slower.", 20, 100, tier(40, 45, 50, 67), 0.01f),
			choice("mcopt.shade.clouds.checker", "Píxeles", "Pixels", "Cuántos píxeles se calculan en cada cuadro (el resto se reutiliza).",
				"How many pixels are traced each frame (the rest are reused).", new String[] {"1", "2", "3", "4"},
				new String[] {"Todos", "1 de 4", "1 de 9", "1 de 16"}, new String[] {"All", "1 in 4", "1 in 9", "1 in 16"}, tier(2, 2, 1, 1)),
			num("mcopt.shade.clouds.steps", "Pasos", "Steps", "Muestras por rayo. Más = más detalle y más lento.", "Samples per ray. More = more detail and slower.", 6, 128,
				tier(20, 20, 40, 56), 1, ""),
			num("mcopt.shade.clouds.lightSteps", "Pasos de luz", "Light steps", "Muestras de luz. Más = sombras internas más finas.",
				"Light samples. More = finer inner shading.", 1, 8, tier(3, 3, 4, 5), 1, ""));

		page("Cielo de noche", "Night sky", "Estrellas, Vía Láctea, luna, sol y auroras.", "Stars, Milky Way, moon, sun and auroras.",
			choice("mcopt.shade.aurora", "Auroras", "Auroras", "Cada cuánto salen auroras en las noches despejadas (más en biomas fríos).",
				"How often auroras show on clear nights (more in cold biomes).", new String[] {"off", "rare", "auto", "always"},
				new String[] {"Nunca", "Pocas", "Normal", "Siempre"}, new String[] {"Never", "Rare", "Normal", "Always"}, () -> 2),
			pct(U + "auroraBrightness", "Brillo de auroras", "Aurora brightness", "Qué tan intensas son las auroras.", "How bright auroras are.", 0, 300, 100),
			pct(U + "stars", "Estrellas", "Stars", "Brillo de las estrellas.", "How bright the stars are.", 0, 400, 100),
			pct(U + "milkyWay", "Vía Láctea", "Milky Way", "Brillo de la Vía Láctea.", "How bright the Milky Way is.", 0, 400, 100),
			toggle(U + "moonPhases", "Fases de la luna", "Moon phases", "No = siempre luna llena.", "Off = always a full moon.", true),
			pct(U + "sunSize", "Tamaño del sol", "Sun size", "Tamaño del disco del sol (las sombras no cambian).", "Size of the sun's disc (shadows don't change).", 30, 400, 100),
			pct(U + "moonSize", "Tamaño de la luna", "Moon size", "Tamaño del disco de la luna.", "Size of the moon's disc.", 30, 400, 100),
			toggle("mcopt.shade.stars", "Cielo propio", "Shader sky", "Sol, luna con fases, estrellas y Vía Láctea del shader. No = los de Minecraft.",
				"The shader's sun, moon phases, stars and Milky Way. Off = Minecraft's.", true));

		page("Agua", "Water", "Color, olas, reflejos, espuma y vista bajo el agua.", "Colour, waves, reflections, foam and underwater view.",
			choice("mcopt.shade.water.color", "Color", "Colour", "Natural: el color de cada bioma, como en Minecraft. Los demás: el mismo color en todo el mundo.",
				"Natural: each biome's colour, as in Minecraft. The others: one colour everywhere.", new String[] {"natural", "blue", "turquoise", "green", "clear"},
				new String[] {"Natural", "Azul", "Turquesa", "Verde", "Cristalina"}, new String[] {"Natural", "Blue", "Turquoise", "Green", "Clear"}, () -> 0),
			pctInt("mcopt.shade.water.clarity", "Transparencia", "Clarity", "Qué tan lejos se ve dentro del agua.", "How far you can see into the water.", 25, 300, 100),
			pct("mcopt.shade.waterWaves", "Olas", "Waves", "La altura de las olas.", "How high the waves are.", 0, 200, 100),
			pct(U + "waveSpeed", "Ritmo de olas", "Wave speed", "Qué tan rápido se mueve el agua.", "How fast the water moves.", 0, 300, 100),
			pct("mcopt.shade.waterReflect", "Reflejos", "Reflections", "Qué tanto refleja el agua.", "How strongly the water reflects.", 0, 200, 100),
			toggle(U + "ssr", "Reflejo del paisaje", "Scene reflections", "El agua refleja montañas, árboles y nubes en pantalla. No = solo el cielo (más FPS junto a lagos).",
				"Water mirrors hills, trees and clouds on screen. Off = sky only (more FPS around lakes).", true),
			num("mcopt.shade.ssrDist", "Alcance reflejo", "Mirror reach", "Hasta dónde busca qué reflejar.", "How far it looks for things to mirror.", 32, 1024,
				() -> 512, 1, ""),
			pct(U + "glint", "Destello del sol", "Sun glint", "El brillo del sol sobre las olas.", "The sun's sparkle on the waves.", 0, 300, 100),
			pct(U + "caustics", "Cáusticas", "Caustics", "Las líneas de luz en el fondo.", "The light patterns on the bottom.", 0, 200, 100),
			pct(U + "foam", "Espuma", "Foam", "La espuma en las orillas.", "The foam along the shore.", 0, 300, 100),
			pct(U + "refraction", "Refracción", "Refraction", "Cuánto se deforma el fondo por las olas.", "How much the waves bend the bottom.", 0, 300, 100),
			pctOf("mcopt.shade.water.falls", "Cascadas", "Waterfalls", "Olas en las cascadas y agua blanca en las corrientes.",
				"Ripples on waterfalls and white water in currents.", 0, 200, () -> 100, 0.01f),
			pctOf("mcopt.shade.water.torchCaustics", "Cáusticas antorcha", "Torch caustics", "Las líneas de luz de las antorchas bajo el agua.",
				"Torch light patterns under water.", 0, 200, () -> 100, 0.01f),
			pct(U + "underwaterView", "Vista bajo el agua", "Underwater view", "Qué tan lejos se ve cuando estás bajo el agua.", "How far you can see while under water.", 25, 400, 100),
			toggle("mcopt.shade.glossy", "Vidrio reflejante", "Glossy glass", "El vidrio de color, el hielo, el slime y la miel reflejan como el agua.",
				"Stained glass, ice, slime and honey reflect like water.", false).restart(),
			choice("mcopt.shade.water.style", "Estilo del agua", "Water style", "Photon: superficie lisa como espejo. Píxeles: ondas en cuadritos.",
				"Photon: a smooth mirror surface. Pixel: blocky ripples.", new String[] {"photon", "m21"}, new String[] {"Photon", "Píxeles"},
				new String[] {"Photon", "Pixel"}, () -> 0).restart());

		page("Clima", "Weather", "Suelo mojado, charcos, nieve, lluvia y relámpagos.", "Wet ground, puddles, snow, rain and lightning.",
			pct(U + "wetness", "Suelo mojado", "Wet ground", "Qué tan mojado se ve todo con la lluvia.", "How wet things look in the rain.", 0, 200, 100),
			pct(U + "puddles", "Charcos", "Puddles", "Cuántos charcos se forman.", "How many puddles form.", 0, 200, 100),
			pct(U + "snow", "Nieve acumulada", "Snow cover", "Cuánta nieve se junta al nevar.", "How much snow builds up.", 0, 200, 100),
			toggle("mcopt.shade.wetAll", "Todo se moja", "Everything gets wet", "Con lluvia, todo el suelo al aire libre se moja (no solo los charcos).",
				"In rain all open ground gets wet (not just puddles).", true),
			toggle("mcopt.shade.wetWalls", "Paredes mojadas", "Wet walls", "Las paredes también se oscurecen con la lluvia.", "Walls darken in the rain too.", true),
			pctOf("mcopt.shade.wetDark", "Oscurecer mojado", "Wet darkening", "Qué tanto se oscurece lo mojado.", "How much wet things darken.", 0, 250, () -> 100, 0.002f),
			pctOf("mcopt.shade.weatherTime", "Secado", "Drying speed", "Qué tan rápido se moja y se seca todo.",
				"How fast things get wet and dry.", 10, 1000, () -> 100, 0.01f),
			toggle("mcopt.shade.rainSlant", "Lluvia inclinada", "Slanted rain", "La lluvia se inclina con el viento.", "Rain leans with the wind.", true),
			toggle("mcopt.shade.lightning", "Luz de relámpagos", "Lightning light", "Los relámpagos iluminan el paisaje.", "Lightning lights up the land.", true),
			num("mcopt.shade.flashLight", "Brillo relámpagos", "Lightning brightness", "Qué tan fuerte iluminan.", "How strongly they light things.", 0, 100, () -> 50, 10, ""),
			toggle("mcopt.shade.snowLine", "Nieve solo en lo alto", "Snow only up high", "En biomas templados, nieva solo arriba de la línea de nieve.",
				"In temperate biomes snow only falls above the snow line.", true));

		page("Nether y End", "Nether and End", "Niebla, luz y cielo de las otras dimensiones.", "Fog, light and sky of the other dimensions.",
			toggle("mcopt.shade.dims.pause", "Efectos Nether/End", "Nether/End effects", "Luz, niebla y cielo propios del shader en el Nether y el End.",
				"The shader's own light, fog and sky in the Nether and the End.", true, true),
			choice("mcopt.shade.dims.netherLight", "Luz del Nether", "Nether lighting", "Completa: luz por píxel. Rápida: la del juego.", "Full: per-pixel light. Fast: the game's.",
				new String[] {"full", "vanilla"}, new String[] {"Completa", "Rápida"}, new String[] {"Full", "Fast"}, () -> 0),
			pct(U + "netherFog", "Niebla del Nether", "Nether fog", "Qué tan espesa es la niebla del Nether.", "How thick the Nether's fog is.", 0, 300, 100),
			pct(U + "netherFogGlow", "Brillo de la niebla", "Fog glow", "Qué tanto brilla la niebla del Nether.", "How much the Nether's fog glows.", 0, 300, 100),
			pct(U + "netherLight", "Luz del ambiente", "Ambient light", "La luz general del Nether.", "The Nether's overall light.", 0, 300, 100),
			pct(U + "lavaGlow", "Brillo de la lava", "Lava glow", "La luz de los mares de lava hacia arriba.", "The lava seas' light upward.", 0, 300, 100),
			toggle("mcopt.shade.netherShimmer", "Calor sobre la lava", "Heat shimmer", "El aire caliente ondula a lo lejos.", "Hot air shimmers in the distance.", Shade.TIER >= 2),
			toggle("mcopt.shade.dims.motes", "Partículas visibles", "Visible particles", "Las esporas y cenizas oscuras se ven mejor.", "Dark spores and ash stay visible.", true),
			pct(U + "endFog", "Niebla del End", "End fog", "Qué tan espesa es la niebla del End.", "How thick the End's fog is.", 0, 300, 100),
			pct(U + "endLight", "Luz del End", "End light", "La luz general del End.", "The End's overall light.", 0, 300, 100),
			pct(U + "endSky", "Cielo del End", "End sky", "Brillo del cielo del End.", "How bright the End's sky is.", 0, 300, 100),
			toggle("mcopt.shade.media", "En lava o nieve", "Inside lava or snow", "Efecto al tener la cabeza dentro de lava o nieve en polvo.",
				"The effect with your head inside lava or powder snow.", true));

		page("Rendimiento", "Performance", "Resolución dinámica, FPS objetivo, calidad de reflejos y compatibilidad.",
			"Dynamic resolution, target FPS, reflection quality and compatibility.",
			h("Velocidad", "Speed"),
			// (1.2.4, issue #10) the pause menu's Resolution button here too: a share of the output (ShadeResolution, live)
			choice("mcopt.shade.resolution", "Resolución interna", "Internal resolution",
				"En % de la Salida (67% = la calidad de MetalFX, 50% = rendimiento). Auto: la resolución dinámica decide. También en el menú de pausa.",
				"As a % of the Output (67% = MetalFX's Quality, 50% = Performance). Auto: dynamic resolution decides. Also in the pause menu.",
				ShadeResolution.VALUES, new String[] {"Auto", "Nativa", "85%", "75%", "67%", "59%", "50%"},
				new String[] {"Auto", "Native", "85%", "75%", "67%", "59%", "50%"}, () -> 0),
			toggle("mcopt.shade.drs", "Resolución dinámica", "Dynamic resolution", "Con la resolución interna en Auto, la baja un poco para mantener los FPS.",
				"With the internal resolution on Auto, lowers it a little to hold the FPS.", true),
			choice("mcopt.shade.drsFps", "FPS objetivo", "Target FPS", "Los FPS que trata de mantener la resolución dinámica.", "The FPS dynamic resolution tries to hold.",
				new String[] {"30", "45", "60", "80", "90", "120", "144"}, new String[] {"30", "45", "60", "80", "90", "120", "144"},
				new String[] {"30", "45", "60", "80", "90", "120", "144"}, tier(5, 5, 3, 2)),
			pctOf("mcopt.shade.drsFloor", "Resolución mínima", "Lowest resolution",
				"Lo más que puede bajar la resolución dinámica (Auto). No fija la resolución: para eso usa Resolución interna. Con Distant Horizons, Auto no es dinámica.",
				"The lowest dynamic resolution (Auto) may go. It doesn't fix the resolution: use Internal resolution for that. With Distant Horizons, Auto isn't dynamic.",
				40, 100, () -> 55, 0.01f),
			choice("mcopt.shade.ssrSteps", "Calidad de reflejos", "Reflection quality", "Pasos del reflejo del paisaje en el agua.", "Steps of the scene reflections on water.",
				new String[] {"8", "16", "24", "32", "48"}, new String[] {"8", "16", "24", "32", "48"}, new String[] {"8", "16", "24", "32", "48"},
				tier(1, 2, 2, 3)).restart(),
			toggle("mcopt.shade.ssrQuad", "Reflejos rápidos", "Fast reflections", "4 píxeles comparten un reflejo: mucho más rápido.",
				"4 pixels share one reflection: much faster.", Shade.TIER < 3).restart(),
			num("mcopt.shade.dynLights.max", "Luces en movimiento", "Moving lights", "Cuántas luces en movimiento a la vez.", "How many moving lights at once.", 1, 64,
				() -> 64, 1, ""),
			toggle("mcopt.shade.entities", "Mobs iluminados", "Lit mobs", "Mobs, objetos y partículas iluminados por el shader.",
				"Mobs, items and particles lit by the shader.", true).restart(),
			toggle("mcopt.shade.handLight", "Mano iluminada", "Lit hand", "Tu mano iluminada por el shader.", "Your hand lit by the shader.", true)
				.restart(),
			// (1.1.1, macOS 27) for players who see tearing or black/white blocks: MetalSurface.PACE_SYNC (on by default with
			// shading, Shade.init) and mc_math_mode (MetalDevice)
			h("Compatibilidad", "Compatibility"),
			toggle("mcopt.metal.paceSync", "Sin tearing", "No tearing", "Con VSync apagado, cada cuadro espera el refresco de la pantalla para no verse cortado.",
				"With VSync off, each frame waits for the screen's refresh so it isn't cut in two (tearing).", true).restart(),
			choice("mcopt.shade.mathMode", "Cálculo de shaders", "Shader math",
				"Preciso: prueba esto si ves cuadros negros o blancos que crecen (por ejemplo en macOS 27). Puede costar algo de FPS.",
				"Precise: try this if you see black or white blocks that grow (for example on macOS 27). May cost some FPS.",
				new String[] {"fast", "relaxed"}, new String[] {"Rápido", "Preciso"}, new String[] {"Fast", "Precise"}, () -> 0).restart());
		// (1.2.2) with Distant Horizons: its quality as presets tested with the shaders (ShadeDh.PRESETS), on the same page
		if (mcopt.metal.shade.dh.ShadeDh.LOADED) PAGES.get(PAGES.size() - 1).items().addAll(List.of(h("Distant Horizons", "Distant Horizons"),
			choice("mcopt.shade.dh.preset", "Distant Horizons", "Distant Horizons",
				"Distancia y detalle del terreno lejano, probados con los shaders. \"Los de DH\": usa tu configuración de Distant Horizons. Con DH, 8 a 12 chunks normales se ven y corren bien.",
				"Distance and detail of the far terrain, tested with the shaders. \"DH's own\": uses your Distant Horizons settings. With DH, 8 to 12 normal chunks look and run well.",
				new String[] {"dh", "performance", "balanced", "quality", "ultra"}, new String[] {"Los de DH", "Rendimiento", "Balanceado", "Calidad", "Ultra"},
				new String[] {"DH's own", "Performance", "Balanced", "Quality", "Ultra"}, () -> 2)));
	}

	private ShadeOptions() {
	}

	/** Every option on every page (and the main page's two). */
	public static List<ShadeOption> all() {
		List<ShadeOption> out = new ArrayList<>(List.of(PRESET, STYLE));
		for (Page p : PAGES) out.addAll(p.options());
		return out;
	}
}
