"""ゲスト定義（vars/guests.yml）と、PVE API から取得した現在の設定との差分を返すフィルタ。"""


def config_drift(desired, current):
    """desired のうち、current と値が違う（または current にない）項目だけを dict で返す。

    API は数値を int で、それ以外を str で返すので、文字列にそろえて比べる。
    """
    current = current or {}
    return {k: v for k, v in desired.items() if str(current.get(k)) != str(v)}


class FilterModule:
    def filters(self):
        return {"config_drift": config_drift}
