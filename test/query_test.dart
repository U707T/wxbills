import 'package:flutter_test/flutter_test.dart';
import 'package:wxbills/src/model/bill.dart';
import 'package:wxbills/src/model/bill_query.dart';

Bill b(String id, int? cents, {String note = ''}) => Bill(
      id: id,
      name: '$id.png',
      path: '/x/$id.png',
      amountCents: cents,
      confidence: 0.9,
      manual: false,
      fileModified: 1700000000000,
      importedAt: 1700000000000,
      updatedAt: 1700000000000,
      note: note,
    );

void main() {
  group('金额查询按「十进制前缀」换算成金额区间', () {
    test('输入 66：命中 66 ~ 66.99，不命中 660 / 166', () {
      final q = BillQuery('66');
      expect(q.isAmount, isTrue);
      expect(q.range, (6600, 6700));
      expect(q.cents, 6600);

      expect(q.matchesAmount(b('a', 6600)), isTrue);
      expect(q.matchesAmount(b('b', 6650)), isTrue,
          reason: '本次要修的正是这条：输入 66 要出现 66.5');
      expect(q.matchesAmount(b('c', 6605)), isTrue);
      expect(q.matchesAmount(b('d', 6699)), isTrue, reason: '区间上界前一分');
      expect(q.matchesAmount(b('e', 6700)), isFalse, reason: '¥67 不属于 66');
      expect(q.matchesAmount(b('f', 66000)), isFalse,
          reason: '660 不是 66 开头，别用字符串包含');
      expect(q.matchesAmount(b('g', 16600)), isFalse);
      expect(q.matchesAmount(b('h', null)), isFalse, reason: '未识别没有金额可比');
    });

    test('输入 66.5：只命中 66.50 ~ 66.59，不再命中 66.05', () {
      final q = BillQuery('66.5');
      expect(q.range, (6650, 6660));
      expect(q.matchesAmount(b('a', 6650)), isTrue);
      expect(q.matchesAmount(b('b', 6655)), isTrue);
      expect(q.matchesAmount(b('c', 6659)), isTrue);
      expect(q.matchesAmount(b('d', 6660)), isFalse);
      expect(q.matchesAmount(b('e', 6605)), isFalse);
      expect(q.matchesAmount(b('f', 6600)), isFalse);
    });

    test('输入两位小数：只命中那一个金额', () {
      final q = BillQuery('66.55');
      expect(q.range, (6655, 6656));
      expect(q.matchesAmount(b('a', 6655)), isTrue);
      expect(q.matchesAmount(b('b', 6650)), isFalse);
    });

    test('小数点还没打完（66.）：等同 66', () {
      final q = BillQuery('66.');
      expect(q.isAmount, isTrue);
      expect(q.range, (6600, 6700));
      expect(q.cents, 6600, reason: '「定位」要能拿它跳');
      expect(q.display, '66', reason: '提示里不该出现「没有 ¥66. 的记录」');
      expect(q.matchesAmount(b('a', 6650)), isTrue);
      expect(q.matchesAmount(b('b', 6600)), isTrue);
    });

    test('.5：就是 0.5x（以前只能精确命中 ¥0.50）', () {
      final q = BillQuery('.5');
      expect(q.isAmount, isTrue);
      expect(q.range, (50, 60));
      expect(q.display, '0.50', reason: '提示里要规整成列表同款金额，别把原始输入塞进去');
      expect(q.matchesAmount(b('a', 50)), isTrue);
      expect(q.matchesAmount(b('b', 55)), isTrue);
      expect(q.matchesAmount(b('c', 6650)), isFalse);
    });

    test('记录显示成「1」但用户输入 1.0 / 1.00：照样命中', () {
      // formatCents 会去掉末尾的 0，¥1.00 在列表里显示成「¥ 1」
      expect(b('a', 100).amountYuan, '1');
      expect(BillQuery('1.0').matchesAmount(b('a', 100)), isTrue);
      expect(BillQuery('1.00').matchesAmount(b('a', 100)), isTrue);
      expect(BillQuery('1').matchesAmount(b('a', 100)), isTrue);
      // 但也别把 ¥10 / ¥100 算进来
      expect(BillQuery('1').matchesAmount(b('b', 1000)), isFalse);
      expect(BillQuery('1').matchesAmount(b('c', 10000)), isFalse);
    });

    test('一个都没命中时给出说明文案（用规整后的金额，不是原始输入）', () {
      expect(BillQuery('66').missHint, '没有 ¥66 的记录');
      expect(BillQuery('66.').missHint, '没有 ¥66 的记录');
      expect(BillQuery(' 66.50 ').missHint, '没有 ¥66.50 的记录');
      expect(BillQuery('0000066').display, '66');
    });

    test('matches() 自己分派：金额走区间，文字走包含', () {
      expect(BillQuery('66').matches(b('a', 6650)), isTrue);
      expect(BillQuery('66').matches(b('a', 1000)), isFalse);
      expect(BillQuery('客户').matches(b('a', 100, note: '客户A')), isTrue);
    });
  });

  group('文字查询（不含金额语义的输入）', () {
    test('名称 / 备注 / 金额文本包含', () {
      final q = BillQuery('客户');
      expect(q.isAmount, isFalse);
      expect(q.range, isNull);
      expect(q.matchesText(b('a', 100, note: '客户A')), isTrue);
      expect(q.matchesText(b('b', 100)), isFalse);

      expect(BillQuery('66元').isAmount, isFalse, reason: '带单位的是文字查询');
      expect(BillQuery('66元').matchesText(b('66元', 6600)), isTrue);
    });
  });
}
