# carray-jit 練習問題 30 問（解答つき）

[07_StepByStep.md](07_StepByStep.md) の日本語版です。ドキュメントが導入する順
に並べた三十の小さな課題と、その解答。おおむね難しくなる順で、星は「subset の
どこまでを使うか」であって、コードの長さではありません。

書いてあるとおりに動きます。まず

```ruby
require "carray"
require "carray/jit"
```

としてください。`#=>` はその行が実際に返す値です。

課題を読み、やってみて、それから見る。コンパイラが断ることが答えである問題で
は、拒否のメッセージがコードの下に出ています。

---

#### 1. `a + b * c` を `out` に、途中の配列を作らず一回の走査で (★☆☆)

`ヒント: 隣に手を伸ばさない仕事のためのメソッド`

```ruby
a = CA_DOUBLE([1, 2, 3])
b = CA_DOUBLE([2, 3, 4])
c = CA_DOUBLE([3, 4, 5])
out = CArray.double(3)

CArray.jit_each { out = a + b * c }
out.to_a                            #=> [7.0, 14.0, 23.0]
```

#### 2. int32 の配列三つで `(a + b * c) / 2` を計算し、結果を新しい配列として受け取る。そのデータ型は？ (★☆☆)

`ヒント: もう一方の要素ごとメソッド`

```ruby
a = CA_INT32([1, 2, 3])
b = CA_INT32([2, 3, 4])
c = CA_INT32([3, 4, 5])

half = CArray.jit_map { (a + b * c) / 2.0 }
half.to_a                           #=> [3.5, 7.0, 11.5]
half.data_type_name                 #=> "float64"
# 型は配列からではなくブロックの最後の値から決まる。`2.0` は自分の幅を持た
# ないので出会った幅を取る。これが無ければ int64。
```

#### 3. 三要素の行を 2x3 の表の全行に足して `out` へ。行は複製せずに (★☆☆)

`ヒント: CArray は軸を伸ばすが、rank は捏造しない`

```ruby
table = CArray.double(2, 3).seq!(1.0)
row = CA_DOUBLE([10, 20, 30]).reshape(1, 3)   # 3 ではなく 1x3。でないと ndim mismatch
out = CArray.double(2, 3)

CArray.jit_each { out = table + row }
out.to_a                            #=> [[11.0, 22.0, 33.0], [14.0, 25.0, 36.0]]
```

#### 4. ブロックが捕まえた Float で、値を変えて二度スケールする。コンパイルは一度だけで、両方の結果を集める (★☆☆)

`ヒント: 特別なことは要らない`

```ruby
a = CA_DOUBLE([1, 2])
out = CArray.double(2)

[2.0, 5.0].map { |gain|
  CArray.jit_each { out = a * gain }   # 捕捉したスカラーは引数であって、
  out.to_a                             # 焼き込まれた定数ではない
}                                   #=> [[2.0, 4.0], [5.0, 10.0]]
```

#### 5. 自分のデータ型を持つ係数で配列をスケールして `out` へ (★☆☆)

`ヒント: CScalar`

```ruby
a = CA_DOUBLE([1, 2])
gain = CScalar.double() { 2.5 }
out = CArray.double(2)

CArray.jit_each { out = a * gain }
out.to_a                            #=> [2.5, 5.0]
```

#### 6. 各値を `out` へ。負の値はゼロで打ち切って (★☆☆)

`ヒント: 分岐は式`

```ruby
a = CA_DOUBLE([-2, 0, 1.5, 3])
out = CArray.double(4)

CArray.jit_each { out = a < 0.0 ? 0.0 : a }
out.to_a                            #=> [0.0, 0.0, 1.5, 3.0]
```

#### 7. ベクトルを逆順にして `out` へ (★☆☆)

`ヒント: どのセルを読むかをセルが言わねばならない`

```ruby
a = CArray.double(5).seq!(1.0)
out = CArray.double(5)

CArray.jit_for(5) { |i| out[i] = a[4 - i] }
out.to_a                            #=> [5.0, 4.0, 3.0, 2.0, 1.0]
```

#### 8. 階差 `out[i] = a[i] - a[i-1]`。`out[0]` はゼロのまま (★☆☆)

`ヒント: 範囲はどこから始められるか`

```ruby
a = CA_DOUBLE([1, 3, 6, 10])
out = CArray.double(4)

CArray.jit_for(1...4) { |i| out[i] = a[i] - a[i - 1] }
out.to_a                            #=> [0.0, 2.0, 3.0, 4.0]
# 0... ではなく 1...。範囲の検査は書かれたとおりの添字に対してループの前に
# 行われるので、本体の中にガードを置いても通らない。
```

#### 9. `out[i] = 0.5 * a[i] + 0.5 * out[i-1]`、ただし `out[0] = a[0]` (★★☆)

`ヒント: このループが今書いたものを読む`

```ruby
a = CA_DOUBLE([4, 8, 8, 8])
out = CArray.double(4)
out[0] = a[0]

CArray.jit_for(1...4) { |i| out[i] = 0.5 * a[i] + 0.5 * out[i - 1] }
out.to_a                            #=> [4.0, 6.0, 7.0, 7.5]
```

#### 10. 2x3 を転置して 3x2 の `out` へ (★☆☆)

`ヒント: 引数二つ、extent 二つ`

```ruby
a = CArray.double(2, 3).seq!(1.0)
out = CArray.double(3, 2)

CArray.jit_for(2, 3) { |i, j| out[j, i] = a[i, j] }
out.to_a                            #=> [[1.0, 4.0], [2.0, 5.0], [3.0, 6.0]]
```

#### 11. 各行の最大値を `out` へ (★☆☆)

`ヒント: セルの中のループ`

```ruby
a = CA_DOUBLE([[1, 3, 2], [9, 4, 5]])
out = CArray.double(2)

CArray.jit_for(2) { |i|
  best = a[i, 0]
  (1...3).each { |j| best = a[i, j] if a[i, j] > best }
  out[i] = best
}
out.to_a                            #=> [3.0, 9.0]
```

#### 12. int32 の配列を、カーネルが書けるひとつの値に合計する (★☆☆)

`ヒント: ローカルは反復を越えて残らない`

```ruby
a = CArray.int32(10).seq!(1)
total = CScalar.int32() { 0 }

CArray.jit_for(10) { |i| total[] += a[i] }
total[0]                            #=> 55
```

#### 13. 各読みがどのビンに属するかが与えられている。ビンごとの個数を `counts` へ (★★☆)

`ヒント: 添字が添字ではなく値`

```ruby
bin = CA_INT32([0, 2, 1, 1, 0, 1])
counts = CArray.int32(3)

CArray.jit_for(6) { |i| counts[bin[i]] += 1 }
counts.to_a                         #=> [2, 3, 1]
```

#### 14. 各 (x, y) の原点からの距離を `out` へ (★☆☆)

`ヒント: Math`

```ruby
x = CA_DOUBLE([3, 5])
y = CA_DOUBLE([4, 12])
out = CArray.double(2)

CArray.jit_each { out = Math.sqrt(x * x + y * y) }
out.to_a                            #=> [5.0, 13.0]
```

#### 15. `jit_each` に添字を名乗るブロックを、`jit_for` に名乗らないブロックを渡す。何が返るか (★★☆)

`ヒント: どちらも推測しない`

```ruby
a = CA_DOUBLE([1, 2, 3])
out = CArray.double(3)

CArray.jit_each { |i| out[i] = a[i] + 1.0 }
#=> CArray::JIT::Unsupported: this block names the arrays it reaches, so it
#   takes no parameters; for a loop that names its indices, see `jit_for`

CArray.jit_for(3) { out = a + 1.0 }
#=> CArray::JIT::Unsupported: jit_for's block names the cells it is on, so it
#   takes the loop indices as its parameters; a block that names none is
#   element-wise and belongs to jit_each
```

#### 16. 各数が十進で何桁かを `digits` へ (★★☆)

`ヒント: 無くなるまで 10 で割る。それは何回か`

```ruby
value = CA_INT32([7, 42, 1000, 65536])
digits = CArray.int32(4)

CArray.jit_for(4) { |i|
  n = value[i]
  count = 0
  while n > 0                       # 一周で終わるセルもあれば、五周するセルも
    n = n / 10                      # 整数除算、しかも Ruby のもの（床関数）
    count = count + 1
  end
  digits[i] = count
}
digits.to_a                         #=> [1, 2, 4, 5]
```

#### 17. 各行で最初に 4.0 を超える列を `first` へ。無ければ -1 (★★☆)

`ヒント: 見るのをやめる`

```ruby
rows = CA_DOUBLE([[1, 2, 9, 3], [5, 1, 1, 8]])
first = CArray.int32(2)

CArray.jit_for(2) { |i|
  found = -1
  (0...4).each { |j|
    if rows[i, j] > 4.0
      found = j
      break
    end
  }
  first[i] = found
}
first.to_a                          #=> [2, 0]
```

#### 18. 2x3 と 3x2 の積を受け取る (★★☆)

`ヒント: 繰り返される添字`

```ruby
a = CArray.double(2, 3).seq!(1.0)
b = CArray.double(3, 2).seq!(1.0)

CArray.jit_contract { |i, j, k| a[i, k] * b[k, j] }.to_a
#=> [[22.0, 28.0], [49.0, 64.0]]
```

#### 19. 2x3 の配列二つについて、各行 `i` ごとの `x[i, k] * y[i, k]` の `k` についての和を受け取る (★★★)

`ヒント: 行の添字も繰り返されるが、和にしてはいけない`

```ruby
x = CA_DOUBLE([[1, 2, 3], [4, 5, 6]])
y = CA_DOUBLE([[1, 1, 1], [2, 2, 2]])

CArray.jit_contract(:b) { |k| x[b, k] * y[b, k] }.to_a
#=> [6.0, 30.0]
# `b` は呼び出しで名乗り、ブロック引数にはしない。両方は断られる
```

#### 20. 各セルと両隣の和を受け取る。端からはみ出すセルはゼロとして読む (★★☆)

`ヒント: 添字も extent も端も出てこない`

```ruby
a = CA_DOUBLE([1, 2, 3, 4])

CArray.jit_stencil(a, border: :zero) { |w| w[-1] + w[0] + w[1] }.to_a
#=> [3.0, 6.0, 9.0, 7.0]
# border: :zero, :clamp, :wrap は枠を計算し、:mask と :skip は枠のセル自体
# について答える
```

#### 21. 各セルを `out` へ。`UNDEF` はゼロに置き換えて (★★☆)

`ヒント: 一セルについて尋ねる`

```ruby
a = CA_DOUBLE([1, 2, 3])
a[1] = UNDEF
out = CArray.double(3)

CArray.jit_for(3) { |i| out[i] = a[i] == UNDEF ? 0.0 : a[i] }
out.to_a                            #=> [1.0, 0.0, 3.0]
# 欲しい答えが「伝播」なら何も書かない。マスクは入力側で OR され、出力へ
# 勝手に運ばれる
```

#### 22. 3x3 の中央の列に 1, 2, 3 を書く。他はそのまま (★★☆)

`ヒント: カーネルに列を渡す`

```ruby
table = CArray.double(3, 3)
column = table[nil, 1]

CArray.jit_for(3) { |i| column[i] = i + 1.0 }
table.to_a                          #=> [[0.0, 1.0, 0.0], [0.0, 2.0, 0.0], [0.0, 3.0, 0.0]]
```

#### 23. uint64 の配列を、ローカルの累算器で合計する。何に止められ、何で通るか (★★★)

`ヒント: リテラルは自分の幅を持たない`

```ruby
source = CArray.uint64(2).seq!(1)
out = CArray.uint64(1)

CArray.jit_for(1) { |i|
  total = 0
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
#=> CArray::JIT::Unsupported: `total` enters this loop as an Integer and comes
#   back round as a uint64; the value carried to the next pass would change
#   type, and one C variable is one type -- give it one type before the loop
```

```ruby
seed = CScalar.uint64() { 0 }       # データ型を持つ値

CArray.jit_for(1) { |i|
  total = seed
  (0...2).each { |j| total = total + source[j] }
  out[i] = total
}
out.to_a                            #=> [3]
```

#### 24. 後ろからの累積和 `out[i] = a[i] + out[i+1]`。`out[4]` は設定済み (★★★)

`ヒント: ループはどちら向きに走るべきか。そしてそれをどこで言うか`

```ruby
a = CA_DOUBLE([1, 2, 3, 4, 5])
out = CArray.double(5)
out[4] = a[4]

CArray.jit_for(3.step(0, -1)) { |i| out[i] = a[i] + out[i + 1] }
out.to_a                            #=> [15.0, 14.0, 12.0, 9.0, 5.0]
```

```ruby
CArray.jit_for(0...4) { |i| out[i] = a[i] + out[i + 1] }
out.to_a                            #=> [1.0, 2.0, 3.0, 9.0, 5.0]
# 向きを述べる場所は extent だけで、間違って述べても断られない。どのセルも
# そこに残っていたゼロを読んだ
```

#### 25. 0 と 1 の列で、1 が最も長く続いた長さ (★★★)

`ヒント: 反復を越えて残るものが二つあり、どちらも和ではない`

```ruby
flag = CA_INT32([0, 1, 1, 1, 0, 1, 1, 0])
run = CScalar.int32() { 0 }
best = CScalar.int32() { 0 }

CArray.jit_for(8) { |i|
  run[] = flag[i] == 1 ? run[] + 1 : 0
  best[] = run[] if run[] > best[]
}
best[0]                             #=> 3
```

#### 26. 各問い合わせについて、それを超えない最後の格子点の添字を `found` へ (★★★)

`ヒント: 格子は整列している`

```ruby
grid = CA_DOUBLE([0, 1, 4, 9, 16])
query = CA_DOUBLE([0.5, 5.0, 9.0, 12.0])
found = CArray.int32(4)

CArray.jit_for(4) { |i|
  t = query[i]
  low = 0
  high = 4
  while high - low > 1
    middle = (low + high) / 2
    if grid[middle] > t
      high = middle
    else
      low = middle
    end
  end
  found[i] = low
}
found.to_a                          #=> [0, 2, 3, 3]
```

#### 27. 配列から読んだ `bound[i]` まで数える。何に止められ、何で通るか (★★★)

`ヒント: 内側の range はループの前に分かっている`

```ruby
bound = CA_INT32([2, 3])
out = CArray.int32(2)

CArray.jit_for(2) { |i|
  count = 0
  (0...bound[i]).each { |j| count = count + 1 }
  out[i] = count
}
#=> CArray::JIT::Unsupported: an inner loop's range is an integer expression
#   over literals and captured scalars
```

```ruby
CArray.jit_for(2) { |i|
  count = 0
  j = 0
  while j < bound[i]                # データが決める上限を運ぶのは while
    count = count + 1
    j = j + 1
  end
  out[i] = count
}
out.to_a                            #=> [2, 3]
```

#### 28. 複素配列の二乗を `squared` へ、元の絶対値を `size` へ (★★☆)

`ヒント: 他と同じデータ型`

```ruby
z = CA_CMPLX128([Complex(0, 1), Complex(1, 1)])
squared = CArray.cmplx128(2)
size = CArray.double(2)

CArray.jit_each { squared = z * z }
CArray.jit_each { size = z.abs }

squared.to_a                        #=> [(-1.0+0.0i), (0.0+2.0i)]
size.to_a                           #=> [1.0, 1.4142135623730951]
```

#### 29. カーネルの中で引いた [0, 1) の乱数 10 万個で配列を埋める (★★☆)

`ヒント: Ruby の rand ではない。ループは GVL を手放して走る`

```ruby
random = CArray::Rng.new(seed: 3)
draws = CArray.double(100_000)

CArray.jit_for(100_000) { |i| draws[i] = random.random }
draws.mean.round(4)                 #=> 0.5006
# どの引きがどのセルに落ちるかはループの順序。そこが問題になるなら、先に
# CArray#random! で配列を埋めて、そのセルを読む
```

#### 30. int32 のセルを持つローカルを int64 の配列に二乗して書く。ローカルの C の型は？ (★★★)

`ヒント: コンパイルされたものを読む`

```ruby
source = CArray.int32(4).seq!(1)
out = CArray.int64(4)

kernel = CArray.jit_for(4) { |i|
  v = source[i]
  out[i] = v * v
}

kernel.c_source.lines.grep(/int64_t v =/).first.strip
#=> "int64_t v = (int64_t)*(int32_t *)(p_source + (i) * source_s0);"
# `v = source[i]` の側は 64 ビットを要求していない。ローカルの型は本体全体
# から決まり、`v * v` が int64 の配列に着地する
```

---

次に行く先: 引くなら [06_Cheatsheet.md](06_Cheatsheet.md)、一機能一ファイルの
巡回なら [examples/features/](../examples/features)、これら全部を使って何かを
する program なら [examples/applications/](../examples/applications) —
`mandelbrot.rb` は 16 と同じく長さがセルごとに違うループ、`alarm.rb` は 25 をヒステリシス付きで、
`lookup.rb` は 26 を 50 万件の問い合わせで、`sieve.rb` は 27 を裏側から。
