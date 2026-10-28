package core

// FirstRunMessage is the first-run dialog. The download sentence is left out
// when the model is already in place (copied in beforehand, or kept from an
// earlier install), since nothing will be downloaded.
func FirstRunMessage(modelPresent bool) string {
	m := "Koe は、AI に話しかけるための入力です。多少聞き間違えても AI が意味を汲み取るので、直さずにそのまま送って大丈夫です。\n\n"
	if !modelPresent {
		m += "初回は音声認識モデル（約 190MB）をダウンロードします。進み具合はタスクバー右下（^ の中）の Koe アイコンにマウスを乗せると表示されます。\n\n"
	}
	return m + "準備ができたら、右 Alt を押している間だけ話してください。離すと文字起こしして貼り付けます。\n\n文字起こしが遅いと感じたら、アイコンのメニュー「モデル（速さ⇔精度）」で base に軽くしてください（誤変換は増えます）。"
}
