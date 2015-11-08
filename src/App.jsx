import React from 'react';
import SplitPane from 'react-split-pane';
import NimEditor from './NimEditor';

require('./ReactSplitPane.css');

export class App extends React.Component {
  render() {
    return (
      <SplitPane split="vertical" minSize="50">
        <NimEditor/>
        <SplitPane split="horizontal">
          <div>Top</div>
          <div>Bottom</div>
        </SplitPane>
      </SplitPane>
    );
  }
}
