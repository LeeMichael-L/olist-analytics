# Olist Analytics Project

## 1. 项目介绍
本项目基于 Olist 巴西电商公开数据集，模拟数据分析团队对电商平台运营情况进行分析。

项目关注平台增长、用户满意度以及卖家质量三个核心方向，通过 SQL 数仓建模和数据分析方法，发现影响业务表现的关键因素。

## 2. 项目目标
本项目主要回答以下问题：

- 平台交易增长的主要来源是什么？
- 哪些因素影响买家满意度？
- 如何评价卖家质量并识别潜在问题卖家？

## 3. 数据来源
本项目使用以下公开数据集：

- Brazilian E-Commerce Public Dataset by Olist

  https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce

- Marketing Funnel by Olist

  https://www.kaggle.com/datasets/olistbr/marketing-funnel-olist

## 4. 当前状态
  阶段1（数据准备与质量审计）已完成：两个数据集共11张表已导入 MySQL，完成数据质量审计、DWD 层清洗和数据全景概览。相关决策见 `docs/decision_log.md`，阶段总结见 `docs/stage_summaries/stage_1.md`。

下一步：阶段2，核心业务分析。